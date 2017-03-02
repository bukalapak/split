# frozen_string_literal: true
require 'spec_helper'
require 'split/score'

describe Split::Score do
  before(:each) do
    Split.configuration.experiments = {
      experiment1: {
        alternatives: %w(alt1 alt2),
        scores: %w(score1 score2)
      },
      experiment2: {
        alternatives: %w(alt1 alt2),
        scores: %w(score1 score3)
      }
    }
    Split::ExperimentCatalog.find_or_create(:experiment1)
    Split::ExperimentCatalog.find_or_create(:experiment2)
  end

  describe '.possible_experiments' do
    it 'should load all experiments having given score' do
      experiment1 = Split::ExperimentCatalog.find(:experiment1)
      experiment2 = Split::ExperimentCatalog.find(:experiment2)
      expect(Split::Score.possible_experiments('score1')).to include(experiment1, experiment2)
      expect(Split::Score.possible_experiments('score3')).to include(experiment2)
      expect(Split::Score.possible_experiments('score4')).to be_empty
    end
  end

  let(:user) { mock_user }
  let(:score_name) { 'score1' }
  let(:label) { 'sample_label' }
  let(:experiments) do
    [
      Split::ExperimentCatalog.find(:experiment1),
      Split::ExperimentCatalog.find(:experiment2)
    ]
  end
  let(:trials) do
    [
      Split::Trial.new(user, experiments[0]),
      Split::Trial.new(user, experiments[1])
    ]
  end
  let(:alternatives) { trials.map(&:alternative) }
  let(:value) { 100 }
  let(:ttl) { 1 }

  describe '.add_delayed' do
    before(:example) do
      user[experiments[0].key] = 'alt2'
      user[experiments[1].key] = 'alt1'
      Split::Score.add_delayed(score_name, label, trials, value, ttl)
    end

    it 'should store the delayed score value' do
      expect(Split::Score.delayed_value(score_name, label)).to eq(value)
    end

    it 'should store the alternatives for the delayed score' do
      delayed_alternatives = Split::Score.delayed_alternatives(score_name, label)
      expect(delayed_alternatives.size).to eq(alternatives.size)
      alternatives.each do |alternative|
        expect(Split::Score.delayed_alternatives(score_name, label)).to include(alternative)
      end
    end

    it 'should delete stored informations when ttl expires' do
      sleep(ttl)
      expect(Split::Score.delayed_value(score_name, label)).to eq(0)
      expect(Split::Score.delayed_alternatives(score_name, label)).to be_empty
    end

    it 'should flag the user as scored for trials' do
      trials.each do |trial|
        expect(trial.user[trial.experiment.scored_key(score_name)]).to be_truthy
      end
    end
  end

  describe '.apply_delayed' do
    before(:example) do
      user[experiments[0].key] = 'alt2'
      user[experiments[1].key] = 'alt1'
      Split::Score.add_delayed(score_name, label, trials, value, ttl)
    end

    context 'when the delayed score exists' do
      before(:example) do
        Split::Score.apply_delayed(score_name, label)
      end

      it 'should add the scores of each stored alternative' do
        expect(alternatives[0].score(score_name)).to eq(value)
        expect(alternatives[1].score(score_name)).to eq(value)
      end

      it 'should delete stored data afterwards' do
        value_key = Split::Score.delayed_value_key(score_name, label)
        alternatives_key = Split::Score.delayed_alternatives_key(score_name, label)
        expect(Split.redis.get(value_key)).to be_nil
        expect(Split.redis.smembers(alternatives_key)).to be_empty
      end
    end

    context 'when the delayed score do not exist' do
      before(:example) do
        Split::Score.apply_delayed(score_name, 'invalid_label')
      end

      it 'should do nothing' do
        expect(alternatives[0].score(score_name)).to eq(0)
        expect(alternatives[1].score(score_name)).to eq(0)
        expect(Split::Score.delayed_value(score_name, label)).not_to be_nil
        expect(Split::Score.delayed_alternatives(score_name, label)).not_to be_empty
      end
    end
  end
end
