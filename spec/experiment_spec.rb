# frozen_string_literal: true

require 'spec_helper'
require 'split/experiment'
require 'split/algorithms'
require 'time'

describe Split::Experiment do
  subject { Split::Experiment }

  before do
    Split.configuration.experiments = {
      link_color: {
        alternatives: %w[blue red green],
        goals: %w[checkout],
        resettable: false,
        metadata:
        {
          blue: 'squirtle',
          red: 'charmender',
          green: 'bulbasaur'
        },
        algorithm: '::Split::Algorithms::Whiplash',
        scores: %w[score1 score2 score3]
      },
      basket_text: {
        alternatives: %w[Basket Cart]
      }
    }
  end

  def new_experiment
    Split::Experiment.new('link_color')
  end

  def alternative(color)
    Split::Alternative.new(color, 'link_color')
  end

  let(:experiment) { new_experiment }

  let(:blue) { alternative('blue') }
  let(:green) { alternative('green') }

  let(:redis) { ::Split.redis }

  context 'with an experiment' do
    let(:experiment) { Split::Experiment.new('basket_text') }

    it 'should have a name' do
      expect(experiment.name).to eq('basket_text')
    end

    it 'should have alternatives' do
      expect(experiment.alternatives.length).to be 2
    end

    it 'should have alternatives with correct names' do
      expect(experiment.alternatives.collect(&:name)).to eq(%w[Basket Cart])
    end

    it 'should be resettable by default' do
      expect(experiment.resettable).to be_truthy
    end

    it 'should have empty (Array) scores by default' do
      expect(experiment.scores).to be_empty
    end

    it 'should save to redis' do
      experiment.save
      expect(Split.redis.sismember(:experiments, 'basket_text')).to be true
    end

    it 'should save the start time to redis' do
      experiment_start_time = Time.at(1_372_167_761)
      expect(Time).to receive(:now).and_return(experiment_start_time)
      experiment.save

      expect(Split::ExperimentCatalog.find('basket_text').start_time).to eq(experiment_start_time)
    end

    it 'should not save the start time to redis when start_manually is enabled' do
      expect(Split.configuration).to receive(:start_manually).and_return(true)
      experiment.save

      expect(Split::ExperimentCatalog.find('basket_text').start_time).to be_nil
    end

    it 'should handle having a start time stored as a string' do
      experiment_start_time = Time.parse('Sat Mar 03 14:01:03')
      expect(Time).to receive(:now).twice.and_return(experiment_start_time)
      experiment.save
      Split.redis.hset(:experiment_start_times, experiment.name, experiment_start_time)

      expect(Split::ExperimentCatalog.find('basket_text').start_time).to eq(experiment_start_time)
    end

    it 'should handle not having a start time' do
      experiment_start_time = Time.parse('Sat Mar 03 14:01:03')
      expect(Time).to receive(:now).and_return(experiment_start_time)
      experiment.save

      Split.redis.hdel(:experiment_start_times, experiment.name)

      expect(Split::ExperimentCatalog.find('basket_text').start_time).to be_nil
    end

    it 'should not create duplicates when saving multiple times' do
      experiment.save
      experiment.save
      expect(Split.redis.sismember(:experiments, 'basket_text')).to be true
    end

    describe 'new record?' do
      it "should know if it hasn't been saved yet" do
        expect(experiment.new_record?).to be_truthy
      end

      it 'should know if it has been saved yet' do
        experiment.save
        expect(experiment.new_record?).to be_falsey
      end
    end

    describe 'control' do
      it 'should be the first alternative' do
        experiment.save
        expect(experiment.control.name).to eq('Basket')
      end
    end
  end

  describe '#initialize' do
    before do
      Split.configure do |config|
        config.experiments = {
          numbers: {
            alternatives: %w[one two three],
            goals: %w[infinite nan],
            metadata: {
              one: 'ein',
              two: 'zwei',
              three: 'drei'
            },
            resettable: false
          }
        }
      end
    end
    context 'when the experiment is defined in configuration' do
      it 'should load the configuration' do
        experiment = subject.new('numbers')
        expect(experiment.name).to eq('numbers')
        expect(experiment.alternatives).not_to be_empty
      end
    end

    context 'when the experiment is not defined in configuration' do
      it 'should only have a name' do
        experiment = subject.new('letters')
        expect(experiment.name).to eq('letters')
        expect(experiment.alternatives).to be_nil
      end
    end
  end

  describe '#load_from_configuration' do
    context 'when the experiment exist in configuration' do
      subject { described_class.new(:link_color) }
      before { subject.load_from_configuration }

      it 'should load the alternatives' do
        expect(subject.alternatives.map(&:name).sort).to eq(%w[blue green red])
      end

      it 'should load the goals' do
        expect(subject.goals).to eq(['checkout'])
      end

      it 'should load the resettable' do
        expect(subject.resettable).to eq(false)
      end

      it 'should load the metadata' do
        expect(subject.metadata).to eq(
          'blue' => 'squirtle',
          'red' => 'charmender',
          'green' => 'bulbasaur'
        )
      end

      it 'should load the algorithm' do
        expect(subject.algorithm).to eq(::Split::Algorithms::Whiplash)
      end

      it 'should load the scores' do
        expect(subject.scores).to eq(%w[score1 score2 score3])
      end
    end

    context 'when the experiment does not exist in configuration' do
      subject { described_class.new(:link_text) }
      it 'should do nothing' do
        expect(subject.load_from_configuration).to be_nil
      end
    end
  end

  describe '#validate!' do
    context 'when the experiment exist in configuration' do
      subject { described_class.new(:link_color) }
      it 'should validate the alternatives' do
        expect { subject.validate! }.not_to raise_error
        allow(subject).to receive(:alternatives).and_return([])
        expect { subject.validate! }.to raise_error(::Split::InvalidExperimentsFormatError)
      end

      it 'should validate the goals' do
        expect { subject.validate! }.not_to raise_error
        allow(subject).to receive(:goals).and_return(%i[goal1 goal2])
        expect { subject.validate! }.to raise_error(::Split::InvalidExperimentsFormatError)
      end

      it 'should validate the metadata' do
        expect { subject.validate! }.not_to raise_error
        allow(subject).to receive(:metadata).and_return(blue: 'squirtle', red: 'charmender', black: 'cory')
        expect { subject.validate! }.to raise_error(::Split::InvalidExperimentsFormatError)
      end

      it 'should validate the algorithm' do
        expect { subject.validate! }.not_to raise_error
        allow(subject).to receive(:algorithm).and_return(String)
        expect { subject.validate! }.to raise_error(::Split::InvalidExperimentsFormatError)
      end

      it 'should validate the scores' do
        expect { subject.validate! }.not_to raise_error
        allow(subject).to receive(:scores).and_return(%i[score1 score2])
        expect { subject.validate! }.to raise_error(::Split::InvalidExperimentsFormatError)
      end
    end

    context 'when the experiment does not exist in configuration' do
      subject { described_class.new(:link_text) }
      it 'should raise an error' do
        expect { subject.validate! }.to raise_error(::Split::InvalidExperimentsFormatError)
      end
    end
  end

  describe '#save' do
    context 'when the experiment does not valid' do
      subject { described_class.new(:link_color) }
      before do
        allow(subject).to receive(:alternatives).and_return([])
      end
      it 'should raise an error' do
        expect(subject).not_to receive(:persist_configuration)
        expect { subject.save }.to raise_error(::Split::InvalidExperimentsFormatError)
      end
    end

    context 'when the experiment already saved before' do
      subject { described_class.new(:link_color) }

      before do
        subject.save
      end

      it 'should do nothing' do
        expect(subject).not_to receive(:persist_configuration)
        subject.save
      end
    end

    context 'when the experiment is new' do
      subject { described_class.new(:link_color) }

      it 'should persist its configuration into redis' do
        subject.save
        expect(redis.sismember(:experiments, subject.name)).to be(true)
        expect(redis.lrange(subject.name, 0, -1)).to eq(subject.alternatives.map(&:name))
        expect(redis.lrange("#{subject.name}:goals", 0, -1)).to eq(subject.goals)
        expect(redis.lrange("#{subject.name}:scores", 0, -1)).to eq(subject.scores)
      end
    end
  end

  describe '#delete' do
    subject { described_class.new('basket_text') }
    before { subject.save }

    it 'should delete itself' do
      subject.delete
      expect(Split::ExperimentCatalog.find('link_color')).to be_nil
    end

    it 'should increment the version' do
      expect(subject.version).to eq(0)
      subject.delete
      expect(subject.version).to eq(1)
    end

    it 'should call the on_experiment_delete hook' do
      expect(Split.configuration.on_experiment_delete).to receive(:call)
      subject.delete
    end

    it 'should call the on_before_experiment_delete hook' do
      expect(Split.configuration.on_before_experiment_delete).to receive(:call)
      subject.delete
    end

    it 'should reset the start time if the experiment should be manually started' do
      Split.configuration.start_manually = true
      subject.start
      subject.delete
      expect(subject.start_time).to be_nil
    end

    it 'should delete its persisted configuration' do
      subject.delete
      expect(redis.sismember(:experiments, subject.name)).to be(false)
      expect(redis.exists(subject.name)).to be(false)
      expect(redis.exists("#{subject.name}:goals")).to be(false)
      expect(redis.exists("#{subject.name}:scores")).to be(false)
    end
  end

  describe '#load_from_redis' do
    subject { described_class.new('sample_experiment') }
    before do
      redis.sadd(:experiments, 'sample_experiment')
      redis.rpush('sample_experiment', %w[alt1 alt2])
      redis.rpush('sample_experiment:goals', %w[goal1 goal2])
      redis.rpush('sample_experiment:scores', %w[score1 score2])
    end

    it 'should load experiment configuration from redis even if the experiment not defined in configuration' do
      subject.load_from_redis
      expect(subject.alternatives.map(&:name)).to eq(%w[alt1 alt2])
      expect(subject.goals).to eq(%w[goal1 goal2])
      expect(subject.scores).to eq(%w[score1 score2])
    end
  end

  describe 'winner' do
    it 'should have no winner initially' do
      expect(experiment.winner).to be_nil
    end

    it 'should allow you to specify a winner' do
      experiment.save
      experiment.winner = 'red'
      expect(experiment.winner.name).to eq('red')
    end
  end

  describe 'has_winner?' do
    context 'with winner' do
      before { experiment.winner = 'red' }

      it 'returns true' do
        expect(experiment).to have_winner
      end
    end

    context 'without winner' do
      it 'returns false' do
        expect(experiment).to_not have_winner
      end
    end
  end

  describe 'reset' do
    let(:reset_manually) { false }

    before do
      allow(Split.configuration).to receive(:reset_manually).and_return(reset_manually)
      experiment.save
      green.increment_participation
      green.increment_participation
    end

    it 'should reset all alternatives' do
      experiment.winner = 'green'

      expect(experiment.next_alternative.name).to eq('green')
      green.increment_participation

      experiment.reset

      expect(green.participant_count).to eq(0)
      expect(green.completed_count).to eq(0)
    end

    it 'should reset the winner' do
      experiment.winner = 'green'

      expect(experiment.next_alternative.name).to eq('green')
      green.increment_participation

      experiment.reset

      expect(experiment.winner).to be_nil
    end

    it 'should increment the version' do
      expect(experiment.version).to eq(0)
      experiment.reset
      expect(experiment.version).to eq(1)
    end

    it 'should call the on_experiment_reset hook' do
      expect(Split.configuration.on_experiment_reset).to receive(:call)
      experiment.reset
    end

    it 'should call the on_before_experiment_reset hook' do
      expect(Split.configuration.on_before_experiment_reset).to receive(:call)
      experiment.reset
    end
  end

  describe 'algorithm' do
    before(:example) do
      Split.configuration.experiments = {
        link_color: {
          alternatives: %w[blue red green]
        }
      }
    end

    let(:experiment) { Split::ExperimentCatalog.find_or_create('link_color') }

    it 'should use the default algorithm if none is specified' do
      expect(experiment.algorithm).to eq(Split.configuration.algorithm)
    end

    it 'should use the user specified algorithm for this experiment if specified' do
      Split.configure do |config|
        config.algorithm = Split::Algorithms::Whiplash
      end
      expect(experiment.algorithm).to eq(Split::Algorithms::Whiplash)
    end
  end

  describe '#next_alternative' do
    context 'with multiple alternatives' do
      before(:example) do
        Split.configuration.experiments = {
          link_color: {
            alternatives: %w[blue red green]
          }
        }
      end

      let(:experiment) { Split::ExperimentCatalog.find_or_create('link_color') }

      context 'with winner' do
        it 'should always return the winner' do
          green = Split::Alternative.new('green', 'link_color')
          experiment.winner = 'green'

          expect(experiment.next_alternative.name).to eq('green')
          green.increment_participation

          expect(experiment.next_alternative.name).to eq('green')
        end
      end

      context 'without winner' do
        it 'should use the specified algorithm' do
          Split.configure do |config|
            config.algorithm = Split::Algorithms::Whiplash
          end
          expect(experiment.algorithm).to receive(:choose_alternative).and_return(Split::Alternative.new('green', 'link_color'))
          expect(experiment.next_alternative.name).to eq('green')
        end
      end
    end
  end

  describe 'beta probability calculation' do
    before(:example) do
      Split.configuration.experiments = {
        mathematicians: {
          alternatives: %w[bernoulli poisson lagrange]
        },
        scientists: {
          alternatives: %w[einstein bohr]
        },
        link_color3: {
          alternatives: %w[blue red green],
          goals: %w[purchase refund]
        }
      }
    end

    it 'should return a hash with the probability of each alternative being the best' do
      experiment = Split::ExperimentCatalog.find_or_create('mathematicians')
      experiment.calc_winning_alternatives
      expect(experiment.alternative_probabilities).not_to be_nil
    end

    it 'should return between 46% and 54% probability for an experiment with 2 alternatives and no data' do
      experiment = Split::ExperimentCatalog.find_or_create('scientists')
      experiment.calc_winning_alternatives
      expect(experiment.alternatives[0].p_winner).to be_within(0.04).of(0.50)
    end

    it 'should calculate the probability of being the winning alternative separately for each goal' do
      experiment = Split::ExperimentCatalog.find_or_create('link_color3')
      goal1 = experiment.goals[0]
      goal2 = experiment.goals[1]
      experiment.alternatives.each do |alternative|
        alternative.participant_count = 50
        alternative.set_completed_count(10, goal1)
        alternative.set_completed_count(15 + rand(30), goal2)
      end
      experiment.calc_winning_alternatives
      alt = experiment.alternatives[0]
      p_goal1 = alt.p_winner(goal1)
      p_goal2 = alt.p_winner(goal2)
      expect(p_goal1).not_to be_within(0.04).of(p_goal2)
    end
  end
end
