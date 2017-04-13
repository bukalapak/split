# frozen_string_literal: true

module Split
  class Experiment
    attr_reader :name
    attr_reader :algorithm
    attr_reader :resettable
    attr_reader :goals
    attr_reader :alternatives
    attr_reader :alternative_probabilities
    attr_reader :metadata
    attr_reader :scores

    def initialize(name)
      @name = name.to_s
      load_from_configuration
    end

    def load_from_configuration
      return unless (config_hash = ::Split.configuration.experiment_for(@name))
      load_alternatives(config_hash)
      load_goals(config_hash)
      load_resettable(config_hash)
      load_metadata(config_hash)
      load_algorithm(config_hash)
      load_scores(config_hash)
    end

    def self.finished_key(key)
      "#{key}:finished"
    end

    def self.scored_key(key, score_name)
      "#{key}:scored:#{score_name}"
    end

    def save
      validate!
      if new_record?
        start unless Split.configuration.start_manually
        persist_configuration
        redis_data[:is_new_record] = false
      end
      self
    end

    def validate!
      validate_alternatives!
      validate_goals!
      validate_metadata!
      validate_algorithm!
      validate_scores!
    end

    def valid?
      validate!
      true
    rescue InvalidExperimentsFormatError
      false
    end

    def new_record?
      redis_data[:is_new_record]
    end

    def ==(other)
      name == other&.name
    end

    def winner
      return nil unless redis_data[:winner_name]
      Split::Alternative.new(redis_data[:winner_name], self)
    end

    def has_winner?
      !winner.nil?
    end

    def winner=(winner_name)
      redis.hset(:experiment_winner, name, winner_name.to_s)
      redis_data[:winner_name] = winner_name.to_s
      winner
    end

    def participant_count
      alternatives.inject(0) { |acc, elem| acc + elem.participant_count }
    end

    def control
      alternatives.first
    end

    def delete_winner
      redis.hdel(:experiment_winner, name)
      redis_data[:winner_name] = nil
    end

    def start
      time = Time.now.to_i
      redis.hset(:experiment_start_times, @name, time)
      redis_data[:start_time] = time.to_s
    end

    def start_time
      t = redis_data[:start_time]
      return unless t
      # Check if stored time is an integer
      if t =~ /^[-+]?[0-9]+$/
        Time.at(t.to_i)
      else
        Time.parse(t)
      end
    end

    def next_alternative
      winner || random_alternative
    end

    def version
      redis_data[:version].to_i
    end

    def increment_version
      redis_data[:version] = redis.incr("#{name}:version")
    end

    def key
      if version.positive?
        "#{name}:#{version}"
      else
        name
      end
    end

    def finished_key
      self.class.finished_key(key)
    end

    def scored_key(score_name)
      self.class.scored_key(key, score_name)
    end

    def resettable?
      resettable
    end

    def reset
      Split.configuration.on_before_experiment_reset.call(self)
      alternatives.each(&:reset)
      delete_winner
      Split.configuration.on_experiment_reset.call(self)
      increment_version
    end

    def delete
      Split.configuration.on_before_experiment_delete.call(self)
      redis.hdel(:experiment_start_times, @name)
      redis_data[:start_time] = nil
      delete_winner
      delete_configuration
      alternatives.each(&:delete)
      Split.configuration.on_experiment_delete.call(self)
      increment_version
    end

    def load_from_redis
      redis_config = redis.pipelined do
        redis.lrange(@name, 0, -1)
        redis.lrange("#{@name}:goals", 0, -1)
        redis.lrange("#{@name}:scores", 0, -1)
      end
      @alternatives = redis_config[0].map { |alt_name| ::Split::Alternative.new(alt_name, self) }
      @goals = redis_config[1]
      @scores = redis_config[2]
    end

    def calc_winning_alternatives
      if goals.empty?
        estimate_winning_alternative
      else
        goals.each do |goal|
          estimate_winning_alternative(goal)
        end
      end
      self
    end

    def jstring(goal = nil)
      js_id = if goal.nil?
                name
              else
                name + '-' + goal
              end
      js_id.gsub('/', '--')
    end

    private

    def redis
      ::Split.redis
    end

    def redis_data
      return @redis_data if defined?(@redis_data)
      @redis_data = {}
      redis_results = redis.pipelined do
        redis.get("#{@name}:version")
        redis.hget(:experiment_winner, @name)
        redis.hget(:experiment_start_times, @name)
        redis.sismember(:experiments, @name)
      end
      @redis_data[:version] = redis_results[0]
      @redis_data[:winner_name] = redis_results[1]
      @redis_data[:start_time] = redis_results[2]
      @redis_data[:is_new_record] = !redis_results[3]
      @redis_data
    end

    def load_alternatives(config_hash)
      alts_config = config_hash[:alternatives]
      alt_names =
        case alts_config
        when Hash
          alts_config.keys
        when Array
          alts_config.flatten
        else
          []
        end
      @alternatives = alt_names.map { |alt_name| ::Split::Alternative.new(alt_name, self) }
    end

    def load_goals(config_hash)
      goals_config = config_hash[:goals]
      @goals = goals_config.is_a?(Array) ? goals_config : []
    end

    def load_resettable(config_hash)
      resettable_config = config_hash[:resettable]
      @resettable = [true, false].include?(resettable_config) ? resettable_config : true
    end

    def load_algorithm(config_hash)
      algorithm_config = config_hash[:algorithm]
      @algorithm = algorithm_config.is_a?(String) ? algorithm_config.constantize : Split.configuration.algorithm
    end

    def load_metadata(config_hash)
      metadata_config = config_hash[:metadata]
      return (@metadata = nil) unless metadata_config.is_a?(Hash)
      @metadata = metadata_config.map { |k, v| [k.to_s, v] }.to_h
    end

    def load_scores(config_hash)
      scores_config = config_hash[:scores]
      @scores = scores_config.is_a?(Array) ? scores_config : []
    end

    def validate_alternatives!
      raise InvalidExperimentsFormatError, 'Experiment must have one or more alternatives' unless alternatives && !alternatives.empty?
      alternatives.each(&:validate!)
    end

    def validate_goals!
      return if goals.all? { |goal| goal.is_a?(String) }
      raise InvalidExperimentsFormatError, 'Experiment goals must be of type String'
    end

    def validate_algorithm!
      raise InvalidExperimentsFormatError, 'Unknown experiment algorithm' unless [
        Split::Algorithms::WeightedSample,
        Split::Algorithms::Whiplash
      ].include?(algorithm)
    end

    def validate_metadata!
      return unless metadata
      return if metadata.keys.sort == alternatives.map(&:name).sort
      raise InvalidExperimentsFormatError, 'Experiment metadata keys must match with its alternatives'
    end

    def validate_scores!
      return if scores.all? { |score| score.is_a?(String) }
      raise InvalidExperimentsFormatError, 'Experiment scores must be of type String'
    end

    def persist_configuration
      redis.multi do
        redis.sadd(:experiments, @name)
        redis.rpush(@name, @alternatives.map(&:name))
        redis.rpush("#{@name}:goals", @goals) unless @goals.empty?
        redis.rpush("#{@name}:scores", @scores) unless @scores.empty?
      end
    end

    def delete_configuration
      redis_data # make sure it's already loaded
      redis.multi do
        redis.srem(:experiments, @name)
        redis.del(@name, "#{@name}:goals", "#{@name}:scores")
        redis_data[:is_new_record] = true
      end
    end

    def delete_alternatives
      @alternatives.each(&:delete)
    end

    def random_alternative
      if alternatives.length > 1
        algorithm.choose_alternative(self)
      else
        alternatives.first
      end
    end

    def estimate_winning_alternative(goal = nil)
      # initialize a hash of beta distributions based on the alternatives' conversion rates
      beta_params = calc_beta_params(goal)

      winning_alternatives = []

      Split.configuration.beta_probability_simulations.times do
        # calculate simulated conversion rates from the beta distributions
        simulated_cr_hash = calc_simulated_conversion_rates(beta_params)

        winning_alternative = find_simulated_winner(simulated_cr_hash)

        # push the winning pair to the winning_alternatives array
        winning_alternatives.push(winning_alternative)
      end

      winning_counts = count_simulated_wins(winning_alternatives)

      @alternative_probabilities = calc_alternative_probabilities(
        winning_counts,
        Split.configuration.beta_probability_simulations
      )

      write_to_alternatives(goal)

      self
    end

    def write_to_alternatives(goal = nil)
      alternatives.each do |alternative|
        alternative.set_p_winner(@alternative_probabilities[alternative], goal)
      end
    end

    def calc_alternative_probabilities(winning_counts, number_of_simulations)
      alternative_probabilities = {}
      winning_counts.each do |alternative, wins|
        alternative_probabilities[alternative] = wins / number_of_simulations.to_f
      end
      alternative_probabilities
    end

    def count_simulated_wins(winning_alternatives)
      # initialize a hash to keep track of winning alternative in simulations
      winning_counts = {}
      alternatives.each do |alternative|
        winning_counts[alternative] = 0
      end
      # count number of times each alternative won, calculate probabilities, place in hash
      winning_alternatives.each do |alternative|
        winning_counts[alternative] += 1
      end
      winning_counts
    end

    def find_simulated_winner(simulated_cr_hash)
      # figure out which alternative had the highest simulated conversion rate
      winning_pair = ['', 0.0]
      simulated_cr_hash.each do |alternative, rate|
        winning_pair = [alternative, rate] if rate > winning_pair[1]
      end
      winner = winning_pair[0]
      winner
    end

    def calc_simulated_conversion_rates(beta_params)
      # initialize a random variable (from which to simulate conversion rates ~beta-distributed)
      rand = SimpleRandom.new
      rand.set_seed

      simulated_cr_hash = {}

      # create a hash which has the conversion rate pulled from each alternative's beta distribution
      beta_params.each do |alternative, params|
        alpha = params[0]
        beta = params[1]
        simulated_conversion_rate = rand.beta(alpha, beta)
        simulated_cr_hash[alternative] = simulated_conversion_rate
      end

      simulated_cr_hash
    end

    def calc_beta_params(goal = nil)
      beta_params = {}
      alternatives.each do |alternative|
        conversions = goal.nil? ? alternative.completed_count : alternative.completed_count(goal)
        alpha = 1 + conversions
        beta = 1 + alternative.participant_count - conversions
        params = [alpha, beta]
        beta_params[alternative] = params
      end
      beta_params
    end
  end
end
