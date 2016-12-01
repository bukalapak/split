# frozen_string_literal: true
require 'spec_helper'
require 'split/score'

describe Split::Score do
  before(:each) do
    Split.configuration.experiments = {
      experiment1: {
        alternatives: ['alt1', 'alt2'],
        scores: ['score1', 'score2']
      },
      experiment2: {
        alternatives: ['alt1', 'alt2'],
        scores: ['score1', 'score3']
      }
    }
  end

  describe '.possible_experiments' do
    it 'should load all experiments having given score' do
      experiment1 = Split::ExperimentCatalog.find_or_create(:experiment1, 'alt1', 'alt2')
      experiment2 = Split::ExperimentCatalog.find_or_create(:experiment2, 'alt1', 'alt2')
      expect(Split::Score.possible_experiments('score1')).to include(experiment1, experiment2)
      expect(Split::Score.possible_experiments('score3')).to include(experiment2)
      expect(Split::Score.possible_experiments('score4')).to be_empty
    end
  end

  describe '.all' do
    def experiments_of_score_name(scores, score_name)
      scores.find { |s| s.name == score_name }.experiments
    end
    it 'should load all scores each with experiments it belongs to' do
      experiment1 = Split::ExperimentCatalog.find_or_create(:experiment1, 'alt1', 'alt2')
      experiment2 = Split::ExperimentCatalog.find_or_create(:experiment2, 'alt1', 'alt2')
      scores = Split::Score.all
      expect(scores.map(&:name)).to include('score1', 'score2', 'score3')
      expect(experiments_of_score_name(scores, 'score1').count).to eq 2
      expect(experiments_of_score_name(scores, 'score1')).to include(experiment1, experiment2)
      expect(experiments_of_score_name(scores, 'score2').count).to eq 1
      expect(experiments_of_score_name(scores, 'score2')).to include(experiment1)
      expect(experiments_of_score_name(scores, 'score3').count).to eq 1
      expect(experiments_of_score_name(scores, 'score3')).to include(experiment2)
    end
  end
end
