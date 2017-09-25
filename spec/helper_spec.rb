# frozen_string_literal: true

require 'spec_helper'

# TODO: change some of these tests to use Rack::Test

describe Split::Helper do
  include Split::Helper

  before(:example) do
    Split.configuration.experiments = {
      link_color: {
        alternatives: [
          { name: 'blue', percent: 10 },
          { name: 'red', percent: 90 }
        ],
        goals: %w[purchase refund]
      },
      link_color2: {
        alternatives: %w[blue red]
      },
      button_size: {
        alternatives: %w[small big]
      },
      my_experiment: {
        alternatives: %w[control_opt second_opt third_opt other_opt]
      }
    }
  end

  let(:experiment) { Split::ExperimentCatalog.find_or_create('link_color') }

  describe '.with_user' do
    let(:given_user) { double('given_user', id: 2) }

    before(:example) do
      allow(given_user).to receive(:try).with(Symbol) { |method_name| given_user.send(method_name) }
    end

    it 'should temporarily use redis adapter as current user persistence scheme' do
      expect(ab_user.user.class.name).to eq('Split::Persistence::SessionAdapter')
      with_user(given_user) do
        expect(ab_user.user.class.name).to eq('Split::Persistence::RedisAdapter')
        expect(ab_user.user.redis_key).to eq("persistence:#{given_user.id}")
      end
      expect(ab_user.user.class.name).to eq('Split::Persistence::SessionAdapter')
    end

    it 'should temporarily change redis adapter class config' do
      Split::Persistence::RedisAdapter.reset_config!
      ori = Split::Persistence::RedisAdapter.config.dup
      with_user(given_user) do
        expect(Split::Persistence::RedisAdapter.config).not_to eq(ori)
        expect(Split::Persistence::RedisAdapter.config[:lookup_by].call(nil)).to eq(given_user.id.to_s)
      end
      expect(Split::Persistence::RedisAdapter.config).to eq(ori)
    end
  end

  describe 'ab_test' do
    it 'should raise the appropriate error when passed integers for alternatives' do
      Split.configuration.experiments = {
        xyz: {
          alternatives: [1, 2, 3]
        }
      }
      expect { Split::ExperimentCatalog.find_or_create(:xyz) }.to raise_error(ArgumentError)
    end

    it 'should raise the appropriate error when passed symbols for alternatives' do
      Split.configuration.experiments = {
        xyz: {
          alternatives: %i[a b c]
        }
      }
      expect { Split::ExperimentCatalog.find_or_create(:xyz) }.to raise_error(ArgumentError)
    end

    it 'should assign a random alternative to a new user when there are an equal number of alternatives assigned' do
      ab_test('link_color')
      expect(%w[red blue]).to include(ab_user['link_color'])
    end

    it 'should increment the participation counter after assignment to a new user' do
      previous_red_count = Split::Alternative.new('red', 'link_color').participant_count
      previous_blue_count = Split::Alternative.new('blue', 'link_color').participant_count

      ab_test('link_color')

      new_red_count = Split::Alternative.new('red', 'link_color').participant_count
      new_blue_count = Split::Alternative.new('blue', 'link_color').participant_count

      expect((new_red_count + new_blue_count)).to eq(previous_red_count + previous_blue_count + 1)
    end

    it 'should not increment the counter for an experiment that the user is not participating in' do
      ab_test('link_color')
      e = Split::ExperimentCatalog.find_or_create('button_size')
      expect(lambda do
        # User shouldn't participate in this second experiment
        ab_test('button_size')
      end).not_to change { e.participant_count }
    end

    it 'should not increment the counter for an ended experiment' do
      e = Split::ExperimentCatalog.find_or_create('button_size')
      e.winner = 'small'
      expect(lambda do
        a = ab_test('button_size')
        expect(a).to eq('small')
      end).not_to change { e.participant_count }
    end

    it 'should not increment the counter for an not started experiment' do
      expect(Split.configuration).to receive(:start_manually).and_return(true)
      e = Split::ExperimentCatalog.find_or_create('button_size')
      expect(lambda do
        a = ab_test('button_size')
        expect(a).to eq('small')
      end).not_to change { e.participant_count }
    end

    it 'should return the given alternative for an existing user' do
      expect(ab_test('link_color')).to eq ab_test('link_color')
    end

    it 'should always return the winner if one is present' do
      experiment.winner = 'orange'

      expect(ab_test('link_color')).to eq('orange')
    end

    it 'should allow the alternative to be forced by passing it in the params' do
      # ?ab_test[link_color]=blue
      @params = { 'ab_test' => { 'link_color' => 'blue' } }

      alternative = ab_test('link_color')
      expect(alternative).to eq('blue')

      @params = { 'ab_test' => { 'link_color' => 'red' } }

      alternative = ab_test('link_color')
      expect(alternative).to eq('red')
    end

    it 'should not allow an arbitrary alternative' do
      @params = { 'ab_test' => { 'link_color' => 'pink' } }
      alternative = ab_test('link_color')
      expect(alternative).not_to eq('pink')
    end

    it 'should not store the split when a param forced alternative' do
      @params = { 'ab_test' => { 'link_color' => 'blue' } }
      expect(ab_user).not_to receive(:[]=)
      ab_test('link_color')
    end

    it 'SPLIT_DISABLE query parameter should also force the alternative (uses control)' do
      @params = { 'SPLIT_DISABLE' => 'true' }
      alternative = ab_test('link_color')
      expect(alternative).to eq('blue')
      alternative = ab_test('link_color2')
      expect(alternative).to eq('blue')
      alternative = ab_test('button_size')
      expect(alternative).to eq('small')
    end

    it 'should not store the split when Split generically disabled' do
      @params = { 'SPLIT_DISABLE' => 'true' }
      expect(ab_user).not_to receive(:[]=)
      ab_test('link_color')
    end

    context 'when store_override is set' do
      before { Split.configuration.store_override = true }

      it 'should store the forced alternative' do
        @params = { 'ab_test' => { 'link_color' => 'blue' } }
        expect(ab_user).to receive(:[]=).with('link_color', 'blue')
        ab_test('link_color')
      end
    end

    context 'when on_trial_choose is set' do
      before { Split.configuration.on_trial_choose = :some_method }
      it 'should call the method' do
        expect(self).to receive(:some_method)
        ab_test('link_color')
      end
    end

    it 'should allow passing a block' do
      alt = ab_test('link_color')
      ret = ab_test('link_color') { |alternative| "shared/#{alternative}" }
      expect(ret).to eq("shared/#{alt}")
    end

    it 'should allow the share of visitors see an alternative to be specified' do
      ab_test('link_color')
      expect(%w[red blue]).to include(ab_user['link_color'])
    end

    it 'should only let a user participate in one experiment at a time' do
      link_color = ab_test('link_color')
      ab_test('button_size')
      expect(ab_user['link_color']).to eq(link_color)
      big = Split::Alternative.new('big', 'button_size')
      expect(big.participant_count).to eq(0)
      small = Split::Alternative.new('small', 'button_size')
      expect(small.participant_count).to eq(0)
    end

    it 'should let a user participate in many experiment with allow_multiple_experiments option' do
      Split.configure do |config|
        config.allow_multiple_experiments = true
        config.experiments[:button_size] = {
          alternatives: %w[small big]
        }
      end
      link_color = ab_test('link_color')
      button_size = ab_test('button_size')
      expect(ab_user['link_color']).to eq(link_color)
      expect(ab_user['button_size']).to eq(button_size)
      button_size_alt = Split::Alternative.new(button_size, 'button_size')
      expect(button_size_alt.participant_count).to eq(1)
    end

    context "with allow_multiple_experiments = 'control'" do
      it "should let a user participate in many experiment with one non-'control' alternative" do
        Split.configure do |config|
          config.allow_multiple_experiments = 'control'
          config.experiments = Array.new(10) do |n|
            [
              "test#{n}".to_sym,
              {
                alternatives: [
                  { name: 'control', percent: 10 - n },
                  { name: "test#{n}-alt", percent: n }
                ]
              }
            ]
          end.to_h
        end
        groups = Array.new(10) do |n|
          ab_test("test#{n}")
        end

        experiments = ab_user.active_experiments
        expect(experiments.size).to be > 1

        count_control = experiments.values.count { |g| g == 'control' }
        expect(count_control).to eq(experiments.size - 1)

        count_alts = groups.count { |g| g != 'control' }
        expect(count_alts).to eq(1)
      end

      context 'when user already has experiment' do
        let(:mock_user) { Split::User.new(self, 'test_0' => 'test-alt') }
        before do
          Split.configure do |config|
            config.allow_multiple_experiments = 'control'
            config.experiments = {
              test_0: {
                alternatives: %w[control test-alt]
              },
              test_1: {
                alternatives: %w[control test-alt]
              }
            }
          end
          Split::ExperimentCatalog.find_or_create('test_0')
          Split::ExperimentCatalog.find_or_create('test_1')
        end

        it 'should restore previously selected alternative' do
          expect(ab_user.active_experiments.size).to eq 1
          expect(ab_test(:test_0)).to eq 'test-alt'
        end

        it 'lets override existing choice' do
          pending 'this requires user store reset on first call not depending on whelther it is current trial'
          @params = { 'ab_test' => { 'test_1' => 'test-alt' } }

          expect(ab_test(:test_0)).to eq 'control'
          expect(ab_test(:test_1)).to eq 'test-alt'
        end
      end
    end

    it 'should not over-write a finished key when an experiment is on a later version' do
      experiment.increment_version
      ab_user = { experiment.key => 'blue', experiment.finished_key => true }
      finished_session = ab_user.dup
      ab_test('link_color')
      expect(ab_user).to eq(finished_session)
    end
  end

  describe 'ab_test_result' do
    before(:example) do
      Split.configuration.experiments = {
        sample_experiment: {
          alternatives: %w[alt1 alt2]
        }
      }
    end
    context 'with the name of an experiment' do
      let(:experiment_name) { 'sample_experiment' }
      context 'when the user enrolls in the experiment' do
        before(:example) { @chosen_alternative = ab_test(experiment_name) }
        it 'should return chosen alternative for current_user' do
          expect(ab_test_result(experiment_name)).to eq @chosen_alternative
        end
      end
      context 'when the user does not participate in the experiment' do
        it 'should return nil' do
          expect(ab_test_result(experiment_name)).to be_nil
        end
      end
    end
  end

  describe 'metadata' do
    before do
      Split.configuration.experiments = {
        my_experiment: {
          alternatives: %w[one two],
          resettable: false,
          metadata: { 'one' => 'Meta1', 'two' => 'Meta2' }
        }
      }
    end

    it 'should be passed to helper block' do
      @params = { 'ab_test' => { 'my_experiment' => 'one' } }
      expect(ab_test('my_experiment')).to eq 'one'
      expect(ab_test('my_experiment') do |_alternative, meta|
        meta
      end).to eq('Meta1')
    end

    it 'should pass empty hash to helper block if library disabled' do
      Split.configure do |config|
        config.enabled = false
      end

      expect(ab_test('my_experiment')).to eq 'one'
      expect(ab_test('my_experiment') do |_, meta|
        meta
      end).to eq({})
    end
  end

  describe 'ab_finished' do
    before(:each) do
      @experiment_name = 'link_color'
      @alternatives = %w[blue red]
      @experiment = Split::ExperimentCatalog.find_or_create(@experiment_name)
      @alternative_name = ab_test(@experiment_name)
      @previous_completion_count = Split::Alternative.new(@alternative_name, @experiment_name).completed_count
    end

    it 'should increment the counter for the completed alternative' do
      ab_finished(@experiment_name)
      new_completion_count = Split::Alternative.new(@alternative_name, @experiment_name).completed_count
      expect(new_completion_count).to eq(@previous_completion_count + 1)
    end

    it "should set experiment's finished key if reset is false" do
      ab_finished(@experiment_name, reset: false)
      expect(ab_user[@experiment.key]).to eq(@alternative_name)
      expect(ab_user[@experiment.finished_key]).to eq(true)
    end

    it 'should not increment the counter if reset is false and the experiment has been already finished' do
      2.times { ab_finished(@experiment_name, reset: false) }
      new_completion_count = Split::Alternative.new(@alternative_name, @experiment_name).completed_count
      expect(new_completion_count).to eq(@previous_completion_count + 1)
    end

    it 'should not increment the counter for an experiment that the user is not participating in' do
      ab_test('button_size')

      # So, user should be participating in the link_color experiment and
      # receive the control for button_size. As the user is not participating in
      # the button size experiment, finishing it should not increase the
      # completion count for that alternative.
      expect(lambda do
        ab_finished('button_size')
      end).not_to change { Split::Alternative.new('small', 'button_size').completed_count }
    end

    it 'should not increment the counter for an ended experiment' do
      e = Split::ExperimentCatalog.find_or_create('button_size')
      e.winner = 'small'
      a = ab_test('button_size')
      expect(a).to eq('small')
      expect(lambda do
        ab_finished('button_size')
      end).not_to change { Split::Alternative.new(a, 'button_size').completed_count }
    end

    it "should clear out the user's participation from their session" do
      expect(ab_user[@experiment.key]).to eq(@alternative_name)
      ab_finished(@experiment_name)
      expect(ab_user.keys).to be_empty
    end

    it 'should not clear out the users session if reset is false' do
      expect(ab_user[@experiment.key]).to eq(@alternative_name)
      ab_finished(@experiment_name, reset: false)
      expect(ab_user[@experiment.key]).to eq(@alternative_name)
      expect(ab_user[@experiment.finished_key]).to eq(true)
    end

    it 'should reset the users session when experiment is not versioned' do
      expect(ab_user[@experiment.key]).to eq(@alternative_name)
      ab_finished(@experiment_name)
      expect(ab_user.keys).to be_empty
    end

    it 'should reset the users session when experiment is versioned' do
      @experiment.increment_version
      @alternative_name = ab_test(@experiment_name)

      expect(ab_user[@experiment.key]).to eq(@alternative_name)
      ab_finished(@experiment_name)
      expect(ab_user.keys).to be_empty
    end

    it 'should do nothing where the experiment was not started by this user' do
      ab_user = nil
      expect(-> { ab_finished('some_experiment_not_started_by_the_user') }).not_to raise_exception
    end

    context 'when on_trial_complete is set' do
      before { Split.configuration.on_trial_complete = :some_method }
      it 'should call the method' do
        expect(self).to receive(:some_method)
        ab_finished(@experiment_name)
      end

      it 'should not call the method without alternative' do
        ab_user[@experiment.key] = nil
        expect(self).not_to receive(:some_method)
        ab_finished(@experiment_name)
      end
    end

    context 'when the experiment does not exist in configuration but recognized from redis' do
      before do
        Split.redis.sadd(:experiments, 'dummy_experiment')
      end
      it 'should do nothing' do
        expect(ab_finished(:dummy_experiment)).to be_nil
      end
    end
  end

  describe '.unscored_user_experiments' do
    before(:example) do
      Split.configuration.experiments = {
        experiment1: {
          alternatives: %w[alt1 alt2],
          scores: %w[score1 score2]
        },
        experiment2: {
          alternatives: %w[alt1 alt2],
          scores: %w[score1 score3]
        }
      }
      Split::ExperimentCatalog.find_or_create(:experiment1)
      Split::ExperimentCatalog.find_or_create(:experiment2)
      Split.configuration.allow_multiple_experiments = true
      ab_user['experiment1'] = 'alt1'
      ab_user['experiment2'] = 'alt2'
    end

    it 'should return all user experiments with given score unscored' do
      result = unscored_user_experiments('score2')
      expect(result.size).to eq(1)
      expect(result.first.name).to eq('experiment1')
    end

    it 'should not return experiments not participated by the user' do
      ab_user['experiment2'] = nil
      expect(unscored_user_experiments('score1')).to_not include(Split::ExperimentCatalog.find(:experiment2))
    end
  end

  # TODO: dry
  describe '.ab_score' do
    before(:example) do
      Split.configuration.experiments = {
        experiment1: {
          alternatives: %w[alt1 alt2],
          scores: %w[score1 score2]
        },
        experiment2: {
          alternatives: %w[alt1 alt2],
          scores: %w[score1 score3]
        }
      }
      Split.configuration.allow_multiple_experiments = true
    end

    def exp_alt(exp_name, alt_name)
      Split::Alternative.new(alt_name, exp_name)
    end

    context 'when in a web session' do
      context 'with ongoing experiments' do
        before(:each) do
          @alt_exp1 = ab_test(:experiment1)
          @alt_exp2 = ab_test(:experiment2)
        end
        context 'with experiments having given score name' do
          before(:each) do
            ab_score('score1', 100)
            ab_score('score2', 200)
          end
          it 'should increment score on the experiments\' chosen alternative by given value' do
            alt_other_exp1 = @alt_exp1 == 'alt1' ? 'alt2' : 'alt1'
            alt_other_exp2 = @alt_exp2 == 'alt1' ? 'alt2' : 'alt1'

            expect(exp_alt(:experiment1, @alt_exp1).score('score1')).to eq 100
            expect(exp_alt(:experiment1, @alt_exp1).score('score2')).to eq 200
            expect(exp_alt(:experiment1, alt_other_exp1).score('score1')).to eq 0
            expect(exp_alt(:experiment1, alt_other_exp1).score('score2')).to eq 0
            expect(exp_alt(:experiment2, @alt_exp2).score('score1')).to eq 100
            expect(exp_alt(:experiment2, @alt_exp2).score('score3')).to eq 0
            expect(exp_alt(:experiment2, alt_other_exp2).score('score1')).to eq 0
            expect(exp_alt(:experiment2, alt_other_exp2).score('score3')).to eq 0
          end

          context 'when the experiment already scored before' do
            before(:each) do
              ab_score('score1', 300)
            end
            it 'should not increment the score' do
              alt_other_exp1 = @alt_exp1 == 'alt1' ? 'alt2' : 'alt1'
              alt_other_exp2 = @alt_exp2 == 'alt1' ? 'alt2' : 'alt1'

              expect(exp_alt(:experiment1, @alt_exp1).score('score1')).to eq 100
              expect(exp_alt(:experiment1, @alt_exp1).score('score2')).to eq 200
              expect(exp_alt(:experiment1, alt_other_exp1).score('score1')).to eq 0
              expect(exp_alt(:experiment1, alt_other_exp1).score('score2')).to eq 0
              expect(exp_alt(:experiment2, @alt_exp2).score('score1')).to eq 100
              expect(exp_alt(:experiment2, @alt_exp2).score('score3')).to eq 0
              expect(exp_alt(:experiment2, alt_other_exp2).score('score1')).to eq 0
              expect(exp_alt(:experiment2, alt_other_exp2).score('score3')).to eq 0
            end
          end
        end

        context 'without any experiments having given score name' do
          before(:each) do
            ab_score('score-1', 300)
          end
          it 'should do nothing' do
            expect(exp_alt(:experiment1, 'alt1').score('score1')).to eq 0
            expect(exp_alt(:experiment1, 'alt1').score('score2')).to eq 0
            expect(exp_alt(:experiment1, 'alt2').score('score1')).to eq 0
            expect(exp_alt(:experiment1, 'alt2').score('score2')).to eq 0
            expect(exp_alt(:experiment2, 'alt1').score('score1')).to eq 0
            expect(exp_alt(:experiment2, 'alt1').score('score3')).to eq 0
            expect(exp_alt(:experiment2, 'alt2').score('score1')).to eq 0
            expect(exp_alt(:experiment2, 'alt2').score('score3')).to eq 0
          end
        end
      end

      context 'with finished experiments having given score name' do
        before(:each) do
          @alt_exp1 = ab_test(:experiment1)
          @alt_exp2 = ab_test(:experiment2)
        end
        context 'finished with reset' do
          before(:each) do
            ab_finished(:experiment1)
            ab_finished(:experiment2)
            ab_score('score1', 100)
            ab_score('score2', 200)
            ab_score('score3', 300)
          end
          it 'should do nothing' do
            expect(exp_alt(:experiment1, 'alt1').score('score1')).to eq 0
            expect(exp_alt(:experiment1, 'alt1').score('score2')).to eq 0
            expect(exp_alt(:experiment1, 'alt2').score('score1')).to eq 0
            expect(exp_alt(:experiment1, 'alt2').score('score2')).to eq 0
            expect(exp_alt(:experiment2, 'alt1').score('score1')).to eq 0
            expect(exp_alt(:experiment2, 'alt1').score('score3')).to eq 0
            expect(exp_alt(:experiment2, 'alt2').score('score1')).to eq 0
            expect(exp_alt(:experiment2, 'alt2').score('score3')).to eq 0
          end
          context 'on next experiment scoring' do
            before(:each) do
              @alt_exp1 = ab_test(:experiment1)
              @alt_exp2 = ab_test(:experiment2)
              ab_score('score1', 42)
              ab_score('score3', 77)
            end
            it 'should increment score on the experiments\' chosen alternative by given value' do
              alt_other_exp1 = @alt_exp1 == 'alt1' ? 'alt2' : 'alt1'
              alt_other_exp2 = @alt_exp2 == 'alt1' ? 'alt2' : 'alt1'
              expect(exp_alt(:experiment1, @alt_exp1).score('score1')).to eq 42
              expect(exp_alt(:experiment1, @alt_exp1).score('score2')).to eq 0
              expect(exp_alt(:experiment1, alt_other_exp1).score('score1')).to eq 0
              expect(exp_alt(:experiment1, alt_other_exp1).score('score2')).to eq 0
              expect(exp_alt(:experiment2, @alt_exp2).score('score1')).to eq 42
              expect(exp_alt(:experiment2, @alt_exp2).score('score3')).to eq 77
              expect(exp_alt(:experiment2, alt_other_exp2).score('score1')).to eq 0
              expect(exp_alt(:experiment2, alt_other_exp2).score('score3')).to eq 0
            end
          end
        end
        context 'finished without reset' do
          before(:each) do
            ab_finished(:experiment1, reset: false)
            ab_finished(:experiment2, reset: false)
            ab_score('score1', 100)
            ab_score('score2', 200)
            ab_score('score3', 300)
          end
          it 'should increment score on the experiments\' chosen alternative by given value' do
            alt_other_exp1 = @alt_exp1 == 'alt1' ? 'alt2' : 'alt1'
            alt_other_exp2 = @alt_exp2 == 'alt1' ? 'alt2' : 'alt1'

            expect(exp_alt(:experiment1, @alt_exp1).score('score1')).to eq 100
            expect(exp_alt(:experiment1, @alt_exp1).score('score2')).to eq 200
            expect(exp_alt(:experiment1, alt_other_exp1).score('score1')).to eq 0
            expect(exp_alt(:experiment1, alt_other_exp1).score('score2')).to eq 0
            expect(exp_alt(:experiment2, @alt_exp2).score('score1')).to eq 100
            expect(exp_alt(:experiment2, @alt_exp2).score('score3')).to eq 300
            expect(exp_alt(:experiment2, alt_other_exp2).score('score1')).to eq 0
            expect(exp_alt(:experiment2, alt_other_exp2).score('score3')).to eq 0
          end
          context 'on next experiment' do
            before(:each) do
              @alt_exp1 = ab_test(:experiment1)
              @alt_exp2 = ab_test(:experiment2)
              ab_score('score1', 42)
              ab_score('score3', 77)
            end
            it 'should do nothing' do
              alt_other_exp1 = @alt_exp1 == 'alt1' ? 'alt2' : 'alt1'
              alt_other_exp2 = @alt_exp2 == 'alt1' ? 'alt2' : 'alt1'

              expect(exp_alt(:experiment1, @alt_exp1).score('score1')).to eq 100
              expect(exp_alt(:experiment1, @alt_exp1).score('score2')).to eq 200
              expect(exp_alt(:experiment1, alt_other_exp1).score('score1')).to eq 0
              expect(exp_alt(:experiment1, alt_other_exp1).score('score2')).to eq 0
              expect(exp_alt(:experiment2, @alt_exp2).score('score1')).to eq 100
              expect(exp_alt(:experiment2, @alt_exp2).score('score3')).to eq 300
              expect(exp_alt(:experiment2, alt_other_exp2).score('score1')).to eq 0
              expect(exp_alt(:experiment2, alt_other_exp2).score('score3')).to eq 0
            end
          end
        end
      end

      context 'with no experiments' do
        it 'should do nothing' do
          expect(exp_alt(:experiment1, 'alt1').score('score1')).to eq 0
          expect(exp_alt(:experiment1, 'alt1').score('score2')).to eq 0
          expect(exp_alt(:experiment1, 'alt2').score('score1')).to eq 0
          expect(exp_alt(:experiment1, 'alt2').score('score2')).to eq 0
          expect(exp_alt(:experiment2, 'alt1').score('score1')).to eq 0
          expect(exp_alt(:experiment2, 'alt1').score('score3')).to eq 0
          expect(exp_alt(:experiment2, 'alt2').score('score1')).to eq 0
          expect(exp_alt(:experiment2, 'alt2').score('score3')).to eq 0
        end
      end
    end

    context 'when not in a web session' do
      before(:each) do
        ab_user = nil
        ab_score('score1', 1)
        ab_score('score2', 1)
        ab_score('score3', 1)
        ab_score('score4', 1)
      end
      it 'should do nothing' do
        expect(exp_alt(:experiment1, 'alt1').score('score1')).to eq 0
        expect(exp_alt(:experiment1, 'alt1').score('score2')).to eq 0
        expect(exp_alt(:experiment1, 'alt2').score('score1')).to eq 0
        expect(exp_alt(:experiment1, 'alt2').score('score2')).to eq 0
        expect(exp_alt(:experiment2, 'alt1').score('score1')).to eq 0
        expect(exp_alt(:experiment2, 'alt1').score('score3')).to eq 0
        expect(exp_alt(:experiment2, 'alt2').score('score1')).to eq 0
        expect(exp_alt(:experiment2, 'alt2').score('score3')).to eq 0
      end
    end
  end

  describe '.ab_add_delayed_score' do
    before(:example) do
      Split.configuration.experiments = {
        experiment1: {
          alternatives: %w[alt1 alt2],
          scores: %w[score1 score2]
        },
        experiment2: {
          alternatives: %w[alt1 alt2],
          scores: %w[score1 score3]
        }
      }
      Split::ExperimentCatalog.find_or_create(:experiment1)
      Split::ExperimentCatalog.find_or_create(:experiment2)
      Split.configuration.allow_multiple_experiments = true
      ab_user['experiment1'] = 'alt1'
      ab_user['experiment2'] = 'alt2'
    end

    context 'with current experiments having given score name' do
      it 'should store the delayed score data' do
        trials = [Split::Trial.new(ab_user, Split::ExperimentCatalog.find(:experiment1))]
        expect(Split::Score).to receive(:add_delayed).once
        ab_add_delayed_score('score2', 'sample_label', 100, 2)
      end
    end
  end

  describe '.ab_apply_delayed_score' do
    it 'should apply any delayed score' do
      allow(Split::Score).to receive(:apply_delayed).and_return(nil)
      expect(Split::Score).to receive(:apply_delayed).once
      Split::Helper.ab_apply_delayed_score('score1', 'sample_label')
    end
  end

  describe '.ab_score_alternative' do
    before(:each) do
      Split.configuration.experiments = {
        experiment1: {
          alternatives: %w[alt1 alt2],
          scores: %w[score1 score2]
        }
      }
      Split::ExperimentCatalog.find_or_create(:experiment1)
      @alt1 = Split::Alternative.new('alt1', :experiment1)
      @alt2 = Split::Alternative.new('alt2', :experiment1)
    end

    context 'with valid input (i.e. everything is exist)' do
      it 'should increment the score of given alternative' do
        Split::Helper.ab_score_alternative(:experiment1, 'alt1', 'score1', 42)

        expect(@alt1.score('score1')).to eq 42
        expect(@alt1.score('score2')).to eq 0
        expect(@alt2.score('score1')).to eq 0
        expect(@alt2.score('score2')).to eq 0
      end
    end

    context 'with invalid input' do
      context 'non existent experiment name' do
        it 'should do nothing' do
          Split::Helper.ab_score_alternative(:experiment2, 'alt1', 'score1', 42)
          expect(@alt1.score('score1')).to eq 0
          expect(@alt1.score('score2')).to eq 0
          expect(@alt2.score('score1')).to eq 0
          expect(@alt2.score('score2')).to eq 0
        end
      end

      context 'non existent alternative name' do
        it 'should do nothing' do
          Split::Helper.ab_score_alternative(:experiment1, 'alt3', 'score1', 42)
          expect(@alt1.score('score1')).to eq 0
          expect(@alt1.score('score2')).to eq 0
          expect(@alt2.score('score1')).to eq 0
          expect(@alt2.score('score2')).to eq 0
        end
      end

      context 'non existent score name' do
        it 'should do nothing' do
          Split::Helper.ab_score_alternative(:experiment1, 'alt1', 'score3', 42)
          expect(@alt1.score('score1')).to eq 0
          expect(@alt1.score('score2')).to eq 0
          expect(@alt2.score('score1')).to eq 0
          expect(@alt2.score('score2')).to eq 0
        end
      end
    end
  end

  context 'finished with config' do
    it 'passes reset option' do
      Split.configuration.experiments = {
        my_experiment: {
          alternatives: %w[one two],
          resettable: false
        }
      }
      alternative = ab_test(:my_experiment)
      experiment = Split::ExperimentCatalog.find(:my_experiment)

      ab_finished(:my_experiment)
      expect(ab_user[experiment.key]).to eq(alternative)
      expect(ab_user[experiment.finished_key]).to eq(true)
    end

    it 'should default resettable to true if nothing provided' do
      Split.configuration.experiments = {
        my_experiment: {
          alternatives: %w[one two]
        }
      }
      ab_test(:my_experiment)
      experiment = Split::ExperimentCatalog.find :my_experiment

      ab_finished :my_experiment
      expect(ab_user[experiment.key]).to be_nil
      expect(ab_user[experiment.finished_key]).to be_nil
    end
  end

  describe 'conversions' do
    it 'should return a conversion rate for an alternative' do
      alternative_name = ab_test('link_color')

      previous_convertion_rate = Split::Alternative.new(alternative_name, 'link_color').conversion_rate
      expect(previous_convertion_rate).to eq(0.0)

      ab_finished('link_color')

      new_convertion_rate = Split::Alternative.new(alternative_name, 'link_color').conversion_rate
      expect(new_convertion_rate).to eq(1.0)
    end
  end

  describe 'active experiments' do
    before(:example) do
      Split.configure do |config|
        config.experiments ||= {}
        config.experiments = config.experiments.merge(
          def: {
            alternatives: %w[4 5 6]
          },
          ghi: {
            alternatives: %w[7 8 9]
          }
        )
      end
    end
    it 'should show an active test' do
      alternative = ab_test('def')
      expect(active_experiments.count).to eq 1
      expect(active_experiments.first[0]).to eq 'def'
      expect(active_experiments.first[1]).to eq alternative
    end

    it 'should show a finished test' do
      alternative = ab_test('def')
      ab_finished('def', reset: false)
      expect(active_experiments.count).to eq 1
      expect(active_experiments.first[0]).to eq 'def'
      expect(active_experiments.first[1]).to eq alternative
    end

    it 'should show an active test when an experiment is on a later version' do
      experiment.reset
      expect(experiment.version).to eq(1)
      ab_test('link_color')
      expect(active_experiments.count).to eq 1
      expect(active_experiments.first[0]).to eq 'link_color'
    end

    it 'should show multiple tests' do
      Split.configure do |config|
        config.allow_multiple_experiments = true
      end
      alternative = ab_test('def')
      another_alternative = ab_test('ghi')
      expect(active_experiments.count).to eq 2
      expect(active_experiments['def']).to eq alternative
      expect(active_experiments['ghi']).to eq another_alternative
    end

    it 'should not show tests with winners' do
      Split.configure do |config|
        config.allow_multiple_experiments = true
      end
      e = Split::ExperimentCatalog.find_or_create('def')
      e.winner = '4'
      alternative = ab_test('def')
      another_alternative = ab_test('ghi')
      expect(active_experiments.count).to eq 1
      expect(active_experiments.first[0]).to eq 'ghi'
      expect(active_experiments.first[1]).to eq another_alternative
    end
  end

  describe 'when user is a robot' do
    before(:each) do
      request.user_agent = 'Googlebot/2.1 (+http://www.google.com/bot.html)'
    end

    describe 'ab_test' do
      it 'should return the control' do
        alternative = ab_test('link_color')
        expect(alternative).to eq experiment.control.name
      end

      it 'should not increment the participation count' do
        previous_red_count = Split::Alternative.new('red', 'link_color').participant_count
        previous_blue_count = Split::Alternative.new('blue', 'link_color').participant_count

        ab_test('link_color')

        new_red_count = Split::Alternative.new('red', 'link_color').participant_count
        new_blue_count = Split::Alternative.new('blue', 'link_color').participant_count

        expect((new_red_count + new_blue_count)).to eq(previous_red_count + previous_blue_count)
      end
    end

    describe 'finished' do
      it 'should not increment the completed count' do
        alternative_name = ab_test('link_color')

        previous_completion_count = Split::Alternative.new(alternative_name, 'link_color').completed_count

        ab_finished('link_color')

        new_completion_count = Split::Alternative.new(alternative_name, 'link_color').completed_count

        expect(new_completion_count).to eq(previous_completion_count)
      end
    end
  end

  describe 'when providing custom ignore logic' do
    context 'using a proc to configure custom logic' do
      before(:each) do
        Split.configure do |c|
          c.ignore_filter = proc { true } # ignore everything
        end
      end

      it 'ignores the ab_test' do
        ab_test('link_color')

        red_count = Split::Alternative.new('red', 'link_color').participant_count
        blue_count = Split::Alternative.new('blue', 'link_color').participant_count
        expect((red_count + blue_count)).to be(0)
      end
    end
  end

  shared_examples_for 'a disabled test' do
    describe 'ab_test' do
      it 'should return the control' do
        alternative = ab_test('link_color')
        expect(alternative).to eq experiment.control.name
      end

      it 'should not increment the participation count' do
        previous_red_count = Split::Alternative.new('red', 'link_color').participant_count
        previous_blue_count = Split::Alternative.new('blue', 'link_color').participant_count

        ab_test('link_color')

        new_red_count = Split::Alternative.new('red', 'link_color').participant_count
        new_blue_count = Split::Alternative.new('blue', 'link_color').participant_count

        expect((new_red_count + new_blue_count)).to eq(previous_red_count + previous_blue_count)
      end
    end

    describe 'finished' do
      it 'should not increment the completed count' do
        alternative_name = ab_test('link_color')

        previous_completion_count = Split::Alternative.new(alternative_name, 'link_color').completed_count

        ab_finished('link_color')

        new_completion_count = Split::Alternative.new(alternative_name, 'link_color').completed_count

        expect(new_completion_count).to eq(previous_completion_count)
      end
    end
  end

  describe 'when ip address is ignored' do
    context 'individually' do
      before(:each) do
        request.ip = '81.19.48.130'
        Split.configure do |c|
          c.ignore_ip_addresses << '81.19.48.130'
        end
      end

      it_behaves_like 'a disabled test'
    end

    context 'for a range' do
      before(:each) do
        request.ip = '81.19.48.129'
        Split.configure do |c|
          c.ignore_ip_addresses << /81\.19\.48\.[0-9]+/
        end
      end

      it_behaves_like 'a disabled test'
    end

    context 'using both a range and a specific value' do
      before(:each) do
        request.ip = '81.19.48.128'
        Split.configure do |c|
          c.ignore_ip_addresses << '81.19.48.130'
          c.ignore_ip_addresses << /81\.19\.48\.[0-9]+/
        end
      end

      it_behaves_like 'a disabled test'
    end

    context 'when ignored other address' do
      before do
        request.ip = '1.1.1.1'
        Split.configure do |c|
          c.ignore_ip_addresses << '81.19.48.130'
        end
      end

      it 'works as usual' do
        alternative_name = ab_test('link_color')
        expect do
          ab_finished('link_color')
        end.to change(Split::Alternative.new(alternative_name, 'link_color'), :completed_count).by(1)
      end
    end
  end

  describe 'versioned experiments' do
    it 'should use version zero if no version is present' do
      alternative_name = ab_test('link_color')
      expect(experiment.version).to eq(0)
      expect(ab_user['link_color']).to eq(alternative_name)
    end

    it 'should save the version of the experiment to the session' do
      experiment.reset
      expect(experiment.version).to eq(1)
      alternative_name = ab_test('link_color')
      expect(ab_user['link_color:1']).to eq(alternative_name)
    end

    it 'should load the experiment even if the version is not 0' do
      experiment.reset
      expect(experiment.version).to eq(1)
      alternative_name = ab_test('link_color')
      expect(ab_user['link_color:1']).to eq(alternative_name)
      return_alternative_name = ab_test('link_color')
      expect(return_alternative_name).to eq(alternative_name)
    end

    it 'should reset the session of a user on an older version of the experiment' do
      alternative_name = ab_test('link_color')
      expect(ab_user['link_color']).to eq(alternative_name)
      alternative = Split::Alternative.new(alternative_name, 'link_color')
      expect(alternative.participant_count).to eq(1)

      experiment.reset
      expect(experiment.version).to eq(1)
      alternative = Split::Alternative.new(alternative_name, 'link_color')
      expect(alternative.participant_count).to eq(0)

      new_alternative_name = ab_test('link_color')
      expect(ab_user['link_color:1']).to eq(new_alternative_name)
      new_alternative = Split::Alternative.new(new_alternative_name, 'link_color')
      expect(new_alternative.participant_count).to eq(1)
    end

    it 'should cleanup old versions of experiments from the session' do
      alternative_name = ab_test('link_color')
      expect(ab_user['link_color']).to eq(alternative_name)
      alternative = Split::Alternative.new(alternative_name, 'link_color')
      expect(alternative.participant_count).to eq(1)

      experiment.reset
      expect(experiment.version).to eq(1)
      alternative = Split::Alternative.new(alternative_name, 'link_color')
      expect(alternative.participant_count).to eq(0)

      new_alternative_name = ab_test('link_color')
      expect(ab_user['link_color:1']).to eq(new_alternative_name)
    end

    it 'should only count completion of users on the current version' do
      alternative_name = ab_test('link_color')
      expect(ab_user['link_color']).to eq(alternative_name)
      alternative = Split::Alternative.new(alternative_name, 'link_color')

      experiment.reset
      expect(experiment.version).to eq(1)

      ab_finished('link_color')
      alternative = Split::Alternative.new(alternative_name, 'link_color')
      expect(alternative.completed_count).to eq(0)
    end
  end

  context 'when redis is not available' do
    before(:each) do
      expect(Split).to receive(:redis).at_most(5).times.and_raise(Errno::ECONNREFUSED.new)
    end

    context 'and db_failover config option is turned off' do
      before(:each) do
        Split.configure do |config|
          config.db_failover = false
        end
      end

      describe 'ab_test' do
        it 'should raise an exception' do
          expect(-> { ab_test('link_color') }).to raise_error(Errno::ECONNREFUSED)
        end
      end

      describe 'finished' do
        it 'should raise an exception' do
          expect(-> { ab_finished('link_color') }).to raise_error(Errno::ECONNREFUSED)
        end
      end

      describe 'disable split testing' do
        before(:each) do
          Split.configure do |config|
            config.enabled = false
          end
        end

        it 'should not attempt to connect to redis' do
          expect(-> { ab_test('link_color') }).not_to raise_error
        end

        it 'should return control variable' do
          expect(ab_test('link_color')).to eq('blue')
          expect(-> { ab_finished('link_color') }).not_to raise_error
        end
      end
    end

    context 'and db_failover config option is turned on' do
      before(:each) do
        Split.configure do |config|
          config.db_failover = true
        end
      end

      describe 'ab_test' do
        it 'should not raise an exception' do
          expect(-> { ab_test('link_color') }).not_to raise_error
        end

        it 'should call db_failover_on_db_error proc with error as parameter' do
          Split.configure do |config|
            config.db_failover_on_db_error = proc do |error|
              expect(error).to be_a(Errno::ECONNREFUSED)
            end
          end

          expect(Split.configuration.db_failover_on_db_error).to receive(:call).and_call_original
          ab_test('link_color')
        end

        it 'should always use first alternative' do
          expect(ab_test('link_color')).to eq('blue')
          expect(ab_test('link_color') do |alternative|
            "shared/#{alternative}"
          end).to eq('shared/blue')
        end

        context 'and db_failover_allow_parameter_override config option is turned on' do
          before(:each) do
            Split.configure do |config|
              config.db_failover_allow_parameter_override = true
            end
          end

          context 'and given an override parameter' do
            it 'should use given override instead of the first alternative' do
              @params = { 'ab_test' => { 'link_color' => 'red' } }
              expect(ab_test('link_color')).to eq('red')
              expect(ab_test('link_color') do |alternative|
                "shared/#{alternative}"
              end).to eq('shared/red')
            end
          end
        end

        context 'and preloaded config given' do
          before do
            Split.configuration.experiments[:link_color] = {
              alternatives: %w[blue red]
            }
          end

          it 'uses first alternative' do
            expect(ab_test(:link_color)).to eq('blue')
          end
        end
      end

      describe 'finished' do
        it 'should not raise an exception' do
          expect(-> { ab_finished('link_color') }).not_to raise_error
        end

        it 'should call db_failover_on_db_error proc with error as parameter' do
          Split.configure do |config|
            config.db_failover_on_db_error = proc do |error|
              expect(error).to be_a(Errno::ECONNREFUSED)
            end
          end

          expect(Split.configuration.db_failover_on_db_error).to receive(:call).and_call_original
          ab_finished('link_color')
        end
      end
    end
  end

  context 'with preloaded config' do
    before { Split.configuration.experiments = {} }

    it 'pulls options from config file' do
      Split.configuration.experiments = Split.configuration.experiments.merge(
        my_experiment: {
          alternatives: %w[control_opt other_opt],
          goals: %w[goal1 goal2]
        }
      )
      ab_test :my_experiment
      expect(Split::Experiment.new(:my_experiment).alternatives.map(&:name)).to eq(%w[control_opt other_opt])
      expect(Split::Experiment.new(:my_experiment).goals).to eq(%w[goal1 goal2])
    end

    it 'can be called multiple times' do
      Split.configuration.experiments = Split.configuration.experiments.merge(
        my_experiment: {
          alternatives: %w[control_opt other_opt],
          goals: %w[goal1 goal2]
        }
      )
      5.times { ab_test :my_experiment }
      experiment = Split::Experiment.new(:my_experiment)
      expect(experiment.alternatives.map(&:name)).to eq(%w[control_opt other_opt])
      expect(experiment.goals).to eq(%w[goal1 goal2])
      expect(experiment.participant_count).to eq(1)
    end

    it 'accepts multiple goals' do
      Split.configuration.experiments = Split.configuration.experiments.merge(
        my_experiment: {
          alternatives: %w[control_opt other_opt],
          goals: %w[goal1 goal2 goal3]
        }
      )
      ab_test :my_experiment
      experiment = Split::Experiment.new(:my_experiment)
      expect(experiment.goals).to eq(%w[goal1 goal2 goal3])
    end

    it 'allow specifying goals to be optional' do
      Split.configuration.experiments = Split.configuration.experiments.merge(
        my_experiment: {
          alternatives: %w[control_opt other_opt]
        }
      )
      experiment = Split::Experiment.new(:my_experiment)
      expect(experiment.goals).to eq([])
    end

    it 'accepts multiple alternatives' do
      Split.configuration.experiments = Split.configuration.experiments.merge(
        my_experiment: {
          alternatives: %w[control_opt second_opt third_opt]
        }
      )
      ab_test :my_experiment
      experiment = Split::Experiment.new(:my_experiment)
      expect(experiment.alternatives.map(&:name)).to eq(%w[control_opt second_opt third_opt])
    end

    it 'accepts probability on alternatives' do
      Split.configuration.experiments = Split.configuration.experiments.merge(
        my_experiment: {
          alternatives: [
            { name: 'control_opt', percent: 67 },
            { name: 'second_opt', percent: 10 },
            { name: 'third_opt', percent: 23 }
          ]
        }
      )
      ab_test :my_experiment
      experiment = Split::Experiment.new(:my_experiment)
      expect(experiment.alternatives.collect { |a| [a.name, a.weight] }).to eq([['control_opt', 0.67], ['second_opt', 0.1], ['third_opt', 0.23]])
    end

    it 'accepts probability on some alternatives' do
      Split.configuration.experiments = Split.configuration.experiments.merge(
        my_experiment: {
          alternatives: [
            { name: 'control_opt', percent: 34 },
            'second_opt',
            { name: 'third_opt', percent: 23 },
            'fourth_opt'
          ]
        }
      )
      ab_test :my_experiment
      experiment = Split::Experiment.new(:my_experiment)
      names_and_weights = experiment.alternatives.collect { |a| [a.name, a.weight] }
      expect(names_and_weights).to eq([['control_opt', 0.34], ['second_opt', 0.215], ['third_opt', 0.23], ['fourth_opt', 0.215]])
      expect(names_and_weights.inject(0) { |sum, nw| sum + nw[1] }).to eq(1.0)
    end

    it 'allows name param without probability' do
      Split.configuration.experiments = Split.configuration.experiments.merge(
        my_experiment: {
          alternatives: [
            { name: 'control_opt' },
            'second_opt',
            { name: 'third_opt', percent: 64 }
          ]
        }
      )
      ab_test :my_experiment
      experiment = Split::Experiment.new(:my_experiment)
      names_and_weights = experiment.alternatives.collect { |a| [a.name, a.weight] }
      expect(names_and_weights).to eq([['control_opt', 0.18], ['second_opt', 0.18], ['third_opt', 0.64]])
      expect(names_and_weights.inject(0) { |sum, nw| sum + nw[1] }).to eq(1.0)
    end

    it 'fails gracefully if config is missing experiment' do
      Split.configuration.experiments = { other_experiment: { alternatives: ['Bar'] } }
      expect(-> { ab_test :my_experiment }).to raise_error(Split::ExperimentNotFound)
    end

    it 'fails gracefully if config is missing' do
      expect(-> { Split.configuration.experiments = nil }).to raise_error(::Split::InvalidExperimentsFormatError)
    end

    it 'fails gracefully if config is missing alternatives' do
      Split.configuration.experiments[:my_experiment] = { foo: 'Bar' }
      expect(-> { ab_test :my_experiment }).to raise_error(::Split::ExperimentNotFound)
    end
  end

  it 'should handle multiple experiments correctly' do
    experiment2 = Split::ExperimentCatalog.find_or_create('link_color2')
    ab_test('link_color')
    ab_test('link_color2')
    ab_finished('link_color2')

    experiment2.alternatives.each do |alt|
      expect(alt.unfinished_count).to eq(0)
    end
  end

  context 'with goals' do
    before do
      @experiment = 'link_color'
      @alternatives = %w[blue red]
      @experiment_name = 'link_color'
      @goals = %w[purchase refund]
      @goal1 = @goals[0]
      @goal2 = @goals[1]
    end

    it 'should normalize experiment' do
      expect(@experiment_name).to eq('link_color')
      expect(@goals).to eq(%w[purchase refund])
    end

    describe 'ab_finished' do
      before do
        @alternative_name = ab_test(@experiment)
      end

      it 'should increment the counter for the specified-goal completed alternative' do
        expect(lambda do
          expect(lambda do
            ab_finished('link_color' => 'purchase')
          end).not_to change {
            Split::Alternative.new(@alternative_name, @experiment_name).completed_count(@goal2)
          }
        end).to change {
          Split::Alternative.new(@alternative_name, @experiment_name).completed_count(@goal1)
        }.by(1)
      end
    end
  end
end
