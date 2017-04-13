# frozen_string_literal: true

module Split
  class Trial
    attr_reader :user
    attr_reader :experiment

    def initialize(user, experiment, context = nil)
      @user = user
      @experiment = experiment
      @context = context
    end

    def metadata
      return nil unless alternative && @experiment.metadata
      @experiment.metadata[alternative.name]
    end

    def alternative
      return @alternative if defined?(@alternative)
      self.alternative = @user[@experiment.key]
      @alternative
    end

    def choose!(override = nil)
      # only cleanup every now and then
      # lazy af method lul but is fine
      @user.cleanup_old_experiments! if rand(100) > 95
      cleanup_old_versions

      store_alternative = false
      if valid_alternative?(override)
        store_alternative = true if Split.configuration.store_override && !alternative && !Split.configuration.disabled? && valid?
        self.alternative = override
      elsif Split.configuration.disabled? || !valid?
        self.alternative = @experiment.control
      elsif @experiment.has_winner?
        self.alternative = @experiment.winner
      elsif !alternative
        store_alternative = true
        self.alternative = @experiment.next_alternative
      end

      if store_alternative
        @user[@experiment.key] = alternative.name
        alternative.increment_participation
        run_callback Split.configuration.on_trial_choose
      end

      run_callback Split.configuration.on_trial unless Split.configuration.disabled?
      alternative
    end

    def complete!(options = { goal: nil })
      return if Split.configuration.disabled? || !valid?
      return if options[:goal] && !@experiment.goals.include?(options[:goal].to_s)
      return unless alternative && !@user[experiment.finished_key]

      run_callback ::Split.configuration.on_trial_complete

      alternative.increment_completion(options[:goal])
      if options.key?(:reset)
        if options[:reset]
          reset!
        else
          @user[experiment.finished_key] = true
        end
      elsif experiment.resettable?
        reset!
      else
        @user[experiment.finished_key] = true
      end
    end

    def score!(score_name, score_value = 1)
      return unless alternative && valid? && !@user[@experiment.scored_key(score_name)] && @experiment.scores.include?(score_name)
      ::Split.redis.multi do
        alternative.increment_score(score_name, score_value)
        @user[@experiment.scored_key(score_name)] = true
      end
    end

    def reset!
      deleted_keys = [@experiment.key, @experiment.finished_key]
      @experiment.scores.each do |score_name|
        deleted_keys << @experiment.scored_key(score_name)
      end
      @user.delete(*deleted_keys)
      @alternative = nil
    end

    private

    def alternative=(alternative)
      @alternative =
        case alternative
        when String
          experiment.alternatives.find { |alt| alt.name == alternative }
        when ::Split::Alternative
          alternative
        end
    end

    def run_callback(callback_name)
      @context.send(callback_name, self) if callback_name && @context.respond_to?(callback_name, true)
    end

    def valid_alternative?(override)
      override = override.name if override.is_a?(::Split::Alternative)
      experiment.alternatives.map(&:name).include?(override)
    end

    def cleanup_old_versions
      @user.cleanup_old_versions!(@experiment) if @experiment.version.positive?
    end

    def valid?
      !(user_excluded? || @experiment.start_time.nil? || @user.max_experiments_reached?(@experiment.key))
    end

    def user_excluded?
      @context.instance_eval(&Split.configuration.ignore_filter) || user_is_bot? || user_ip_ignored?
    end

    def user_is_bot?
      return false unless @context.respond_to?(:request, true)
      @context.send(:request).user_agent =~ Split.configuration.robot_regex
    end

    def user_ip_ignored?
      return false if Split.configuration.ignore_ip_addresses.empty? || !@context.respond_to?(:request, true)

      user_ip = @context.send(:request).ip
      Split.configuration.ignore_ip_addresses.each do |ip|
        return true if user_ip == ip || (ip.class == Regexp && user_ip =~ ip)
      end
      false
    end
  end
end
