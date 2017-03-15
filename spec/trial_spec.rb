# frozen_string_literal: true
require 'spec_helper'
require 'split/trial'

describe Split::Trial do
  before do
    Split.configure do |config|
      config.experiments = {
        basket_text: {
          alternatives: %w(basket cart),
          metadata: Hash[%w(basket cart).map { |k| [k, "Metadata for #{k}"] }],
          goals: %w(first second),
          scores: %w(checkout qty)
        }
      }
    end
  end

  let(:context) { double(on_trial_callback: 'test callback', request: double(user_agent: '007', ip: 'man'), on_trial_complete_callback: 'test callback') }
  let(:user) { mock_user }
  let(:alternatives) { %w(basket cart) }
  let(:experiment) { Split::Experiment.new('basket_text').save }
  let(:trial) { Split::Trial.new(user, experiment, context) }

  describe 'metadata' do
    let(:metadata) { Hash[alternatives.map { |k| [k, "Metadata for #{k}"] }] }
    let(:experiment) do
      Split::Experiment.new('basket_text').save
    end

    it 'has metadata on each trial' do
      user[experiment.key] = 'cart'
      trial = Split::Trial.new(user, experiment, self)
      expect(trial.metadata).to eq(metadata['cart'])
    end

    it 'has metadata on each trial from the experiment' do
      trial = Split::Trial.new(user, experiment, self)
      trial.choose!
      expect(trial.metadata).to eq(metadata[trial.alternative.name])
      expect(trial.metadata).to match(/#{trial.alternative.name}/)
    end
  end

  describe '#choose!' do
    shared_examples_for 'a trial with callbacks' do
      it 'does not run if on_trial callback is not respondable' do
        Split.configuration.on_trial = :foo
        allow(context).to receive(:respond_to?).and_return true
        allow(context).to receive(:respond_to?).with(:foo, true).and_return false
        expect(context).to_not receive(:foo)
        trial.choose!
      end
      it 'runs on_trial callback' do
        Split.configuration.on_trial = :on_trial_callback
        expect(context).to receive(:on_trial_callback)
        trial.choose!
      end
      it 'does not run nil on_trial callback' do
        Split.configuration.on_trial = nil
        expect(context).not_to receive(:on_trial_callback)
        trial.choose!
      end
    end

    def expect_alternative(trial, alternative_name, override = nil)
      3.times do
        trial.choose!(override)
        expect(alternative_name).to include(trial.alternative.name)
      end
    end

    context 'with override' do
      let(:override) { 'cart' }

      it_behaves_like 'a trial with callbacks'

      it 'picks the override' do
        expect(experiment).to_not receive(:next_alternative)
        expect_alternative(trial, override, override)
      end

      context 'when user already chose an alternative before' do
        it 'should not change chosen alternative' do
          chosen = trial.choose!
          unchosen = alternatives.find { |alt| alt != chosen }
          trial.choose!(unchosen)
          expect(user[experiment.key]).to eq chosen.name
        end

        it 'should still return the override' do
          chosen = trial.choose!
          unchosen = alternatives.find { |alt| alt != chosen }
          expect(trial.choose!(unchosen).name).to eq unchosen
        end
      end

      context "when alternative doesn't exist" do
        let(:override) { 'invalid_alt' }
        it 'falls back on next_alternative' do
          expect(experiment).to receive(:next_alternative).and_call_original
          expect_alternative(trial, alternatives)
        end
      end
    end

    context 'when Split is globally disabled' do
      it 'picks the control and does not run on_trial callbacks', :aggregate_failures do
        Split.configuration.enabled = false
        Split.configuration.on_trial = :on_trial_callback

        expect(experiment).to_not receive(:next_alternative)
        expect(context).not_to receive(:on_trial_callback)
        expect_alternative(trial, 'basket')

        Split.configuration.enabled = true
        Split.configuration.on_trial = nil
      end
    end

    context 'when experiment has winner' do
      let(:trial) do
        Split::Trial.new(user, experiment, context)
      end

      it_behaves_like 'a trial with callbacks'

      it 'picks the winner' do
        experiment.winner = 'cart'
        expect(experiment).to_not receive(:next_alternative)

        expect_alternative(trial, 'cart')
      end
    end

    context 'when the user is excluded' do
      let(:trial) do
        Split::Trial.new(user, experiment, context)
      end

      it_behaves_like 'a trial with callbacks'

      shared_examples_for 'trial with excluded user' do
        it 'picks the control' do
          expect(experiment).to_not receive(:next_alternative)
          expect_alternative(trial, 'basket')
        end
      end

      context 'from ignore filter' do
        let(:context) { double(wew: 'lad') }
        before do
          Split.configuration.ignore_filter = proc { wew == 'lad' }
        end
        it_behaves_like 'trial with excluded user'
      end

      context 'from user agent' do
        let(:context) { double(request: double(user_agent: 'BEEP BOOP I IZ ROBOT')) }
        before { Split.configuration.robot_regex = /bot/i }
        it_behaves_like 'trial with excluded user'
      end

      context 'from ip' do
        let(:context) { double(request: double(user_agent: 'BEEP BOOP I IZ ROBOT', ip: '127.0.0.1')) }
        before { Split.configuration.ignore_ip_addresses = [/^127*/] }
        it_behaves_like 'trial with excluded user'
      end
    end

    context 'when user is already participating' do
      it_behaves_like 'a trial with callbacks'

      it 'picks the same alternative' do
        user[experiment.key] = 'basket'
        expect(experiment).to_not receive(:next_alternative)

        expect_alternative(trial, 'basket')
      end
    end

    context 'when user is a new participant' do
      it 'picks a new alternative and runs on_trial_choose callback', :aggregate_failures do
        Split.configuration.on_trial_choose = :on_trial_choose_callback

        expect(experiment).to receive(:next_alternative).and_call_original
        expect(context).to receive(:on_trial_choose_callback)

        trial.choose!

        expect(trial.alternative.name).to_not be_empty
        Split.configuration.on_trial_choose = nil
      end
    end
  end

  describe '#complete!' do
    let(:alternative) { trial.alternative }

    before { trial.choose! }

    shared_examples_for 'trial with complete callback' do
      it 'does not run if on_trial_complete callback is not respondable' do
        Split.configuration.on_trial_complete = :foo
        allow(context).to receive(:respond_to?).and_return true
        allow(context).to receive(:respond_to?).with(:foo, true).and_return false
        expect(context).to_not receive(:foo)
        trial.complete!
      end
      it 'runs on_trial_complete callback' do
        Split.configuration.on_trial_complete = :on_trial_complete_callback
        expect(context).to receive(:on_trial_complete_callback)
        trial.complete!
      end
      it 'does not run nil on_trial callback' do
        Split.configuration.on_trial = nil
        expect(context).not_to receive(:on_trial_complete_callback)
        trial.complete!
      end
      it 'still has trial attributes when the callback gets called' do
        allow(context).to receive(:respond_to?).and_return(true)
        allow(context).to receive(:alternative_name) { |t| t.alternative.name }
        Split.configuration.on_trial_complete = :alternative_name
        expect { trial.complete!(reset: true) }.to_not raise_error
      end
    end

    shared_examples_for 'invalid trial to complete' do
      it 'should do nothing and return nil' do
        expect(trial).to_not receive(:run_callback)
        g = defined?(goal) ? goal : nil
        expect(trial.complete!(goal: g)).to eq(nil)
      end
    end

    context 'when there are no goals' do
      it_behaves_like 'trial with complete callback'

      it 'should complete the trial' do
        expect { trial.complete! }.to change { alternative.completed_count }.by(1)
      end
    end

    context 'with a goal' do
      let(:goal) { experiment.goals.first }

      it_behaves_like 'trial with complete callback'

      it 'should complete the trial with the goal' do
        expect { trial.complete!(goal: goal) }.to change { alternative.completed_count(goal) }.by(1)
      end

      it 'should not complete the trial without the goal' do
        expect { trial.complete!(goal: goal) }.to change { alternative.completed_count }.by(0)
      end
    end

    context 'with reset option' do
      context 'true' do
        let(:reset) { true }
        it_behaves_like 'trial with complete callback'

        it 'should delete user data for the trial' do
          trial.complete!(reset: reset)
          expect(user.keys.select { |key| key =~ /^#{experiment.key}/ }).to be_empty
        end
      end

      context 'false' do
        let(:reset) { false }
        it_behaves_like 'trial with complete callback'

        it 'should flag the user as finished trial' do
          trial.complete!(reset: reset)
          expect(user[experiment.finished_key]).to be_truthy
        end
      end
    end

    context 'when the trial has yet to choose alternative' do
      before { trial.reset! }
      it_behaves_like 'invalid trial to complete'
    end

    context 'with invalid goal' do
      let(:goal) { 'invalid_goal' }
      it_behaves_like 'invalid trial to complete'
    end

    context 'when split is disabled' do
      before { Split.configuration.enabled = false }
      it_behaves_like 'invalid trial to complete'
    end

    context 'when the trial is not valid' do
      before { allow(trial).to receive(:valid?).and_return(false) }
      it_behaves_like 'invalid trial to complete'
    end

    context 'when the trial is already completed' do
      before { trial.complete! }
      it_behaves_like 'invalid trial to complete'
    end
  end

  describe '#score!' do
    let(:score_name) { 'qty' }
    let(:score_value) { 2 }
    let(:alternative) { trial.alternative }

    before { trial.choose! }

    context 'with normal condition' do
      it 'should increment the score of chosen alternative' do
        expect { trial.score!(score_name, score_value) }.to change { alternative.score(score_name) }.by(score_value)
      end

      it 'should flag the user as scored for trial' do
        trial.score!(score_name, score_value)
        expect(user[experiment.scored_key(score_name)]).to be_truthy
      end
    end

    shared_examples_for 'invalid trial to score' do
      it 'should do nothing and return nil' do
        expect(trial.score!(score_name, score_value)).to be_nil
      end
    end

    context 'with invalid score name' do
      let(:score_name) { 'invalid_name' }

      it_behaves_like 'invalid trial to score'
    end

    context 'when the trial has yet to choose alternative' do
      before { trial.reset! }

      it_behaves_like 'invalid trial to score'
    end

    context 'when the trial already scored' do
      before { trial.score!(score_name, score_value) }

      it_behaves_like 'invalid trial to score'
    end
  end

  describe '#reset!' do
    before { trial.reset! }

    it 'should delete user data for the trial' do
      expect(user.keys.select { |key| key =~ /^#{experiment.key}/ }).to be_empty
    end
  end
end
