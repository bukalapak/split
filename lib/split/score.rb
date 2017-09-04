# frozen_string_literal: true

module Split
  class Score
    attr_accessor :name
    attr_accessor :experiments

    def initialize(name, experiments)
      @name = name
      @experiments = experiments
    end

    class << self
      def load_from_configuration(name)
        scores = Split.configuration.scores
        return nil unless scores && scores[name]
        experiments = scores[name].map{ |e| ::Split::Experiment.new(e) }
        Split::Score.new(name, experiments)
      end

      def find(name)
        score = load_from_configuration(name)
        score
      end

      def possible_experiments(score_name)
        score = find(score_name)
        return [] if score.nil?
        score.experiments
      end

      def add_delayed(score_name, label, trials, value = 1, ttl = 60 * 60 * 24)
        val_key = delayed_value_key(score_name, label)
        alt_key = delayed_alternatives_key(score_name, label)
        Split.redis.multi do
          Split.redis.set(val_key, value)
          Split.redis.sadd(alt_key, trials.map(&:alternative).map(&:key))
          Split.redis.expire(val_key, ttl)
          Split.redis.expire(alt_key, ttl)
          trials.each do |trial|
            trial.user[trial.experiment.scored_key(score_name)] = true
          end
        end
      end

      def apply_delayed(score_name, label)
        val_key = delayed_value_key(score_name, label)
        alt_key = delayed_alternatives_key(score_name, label)
        value = delayed_value(score_name, label)
        alternatives = delayed_alternatives(score_name, label)
        Split.redis.multi do
          Split.redis.del(val_key)
          Split.redis.del(alt_key)
          alternatives.each do |alternative|
            alternative.increment_score(score_name, value)
          end
        end
      end

      def delayed_value(score_name, label)
        key = delayed_value_key(score_name, label)
        Split.redis.get(key).to_i
      end

      def delayed_alternatives(score_name, label)
        key = delayed_alternatives_key(score_name, label)
        Split.redis.smembers(key).map do |alternative_key|
          experiment_name, alternative_name = alternative_key.split(':')
          Alternative.new(alternative_name, experiment_name)
        end
      end

      def delayed_key(score_name, label)
        "delayed_score:#{score_name}:#{label}"
      end

      def delayed_value_key(score_name, label)
        "#{delayed_key(score_name, label)}:value"
      end

      def delayed_alternatives_key(score_name, label)
        "#{delayed_key(score_name, label)}:alternatives"
      end
    end # class << self
  end # Score
end # Split
