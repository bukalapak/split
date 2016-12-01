# sorta copy-paste from Split::Metric
module Split
  class Score
    attr_accessor :name
    attr_accessor :experiments

    def initialize(name, experiments)
      @name  = name
      @experiments = experiments
    end

    def self.load_from_configuration(name)
      scores = Split.configuration.scores
      return nil unless scores && scores[name]
      Split::Score.new(name, scores[name])
    end

    def self.find(name)
      score = load_from_configuration(name)
      score
    end

    def self.all
      Split.configuration.scores.map do |name, experiments|
        new(name, experiments)
      end
    end

    def self.possible_experiments(score_name)
      score = find(score_name)
      return [] if score.nil?
      score.experiments
    end
  end # Metric
end # Split
