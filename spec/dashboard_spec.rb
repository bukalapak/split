# frozen_string_literal: true
require 'spec_helper'
require 'rack/test'
require 'split/dashboard'

describe Split::Dashboard do
  include Rack::Test::Methods

  def app
    @app ||= Split::Dashboard
  end

  def link(color)
    Split::Alternative.new(color, experiment.name)
  end

  before(:example) do
    Split.configuration.experiments = {
      link_color: {
        alternatives: [
          { name: 'blue', percent: 50 },
          { name: 'red', percent: 50 }
        ],
        goals: %w(goal_1 goal_2)
      }
    }
  end

  let(:experiment) do
    Split::ExperimentCatalog.find_or_create('link_color')
  end

  let(:red_link) { link('red') }
  let(:blue_link) { link('blue') }

  shared_examples_for 'logged events' do
    context 'with default logger config' do
      it 'should log the event to STDOUT' do
        expect { event_proc.call }.to output(/#{experiment.name}: #{event}/).to_stdout_from_any_process
      end
    end

    context 'with custom logger config' do
      before do
        Split.configuration.logger = Logger.new(STDERR)
        Split.configuration.logger_proc = lambda do |logger, experiment_name, event|
          logger.info("#{event}ing #{experiment_name}")
        end
      end

      it 'should log the event as configured' do
        expect { event_proc.call }.to output(/#{event}ing #{experiment.name}/).to_stderr_from_any_process
      end
    end
  end

  it 'should respond to /' do
    get '/'
    expect(last_response).to be_ok
  end

  context 'start experiment manually' do
    before do
      Split.configuration.start_manually = true
    end

    let(:event_proc) { -> { post "/start?experiment=#{experiment.name}" } }
    let(:event) { 'start' }
    it_behaves_like 'logged events'

    context 'experiment without goals' do
      it 'should display a Start button' do
        get "experiments/#{experiment.name}"
        expect(last_response.body).to include('Start')

        post "/start?experiment=#{experiment.name}"
        get "experiments/#{experiment.name}"
        expect(last_response.body).to include('Reset Data')
      end
    end

    context 'with goals' do
      it 'should display a Start button' do
        get "/experiments/#{experiment.name}"
        expect(last_response.body).to include('Start')

        post "/start?experiment=#{experiment.name}"
        get "/experiments/#{experiment.name}"
        expect(last_response.body).to include('Reset Data')
      end
    end
  end

  describe 'force alternative' do
    let!(:user) do
      Split::User.new(@app, experiment.name => 'a')
    end

    before do
      allow(Split::User).to receive(:new).and_return(user)
    end

    it "should set current user's alternative" do
      post "/force_alternative?experiment=#{experiment.name}", alternative: 'b'
      expect(user[experiment.name]).to eq('b')
    end
  end

  describe 'index page' do
    context 'with winner' do
      before { experiment.winner = 'red' }

      it 'displays `Reopen Experiment` button' do
        get "/experiments/#{experiment.name}"
        expect(last_response.body).to include('Reopen Experiment')
      end
    end

    context 'without winner' do
      it 'should not display `Reopen Experiment` button' do
        get "/experiments/#{experiment.name}"

        expect(last_response.body).to_not include('Reopen Experiment')
      end
    end
  end

  describe 'reopen experiment' do
    before { experiment.winner = 'red' }

    let(:event_proc) { -> { post "/reopen?experiment=#{experiment.name}" } }
    let(:event) { 'reopen' }
    it_behaves_like 'logged events'

    it 'redirects' do
      post "/reopen?experiment=#{experiment.name}"

      expect(last_response).to be_redirect
    end

    it 'removes winner' do
      post "/reopen?experiment=#{experiment.name}"

      updated_experiment = Split::ExperimentCatalog.find experiment.name
      expect(updated_experiment).to_not have_winner
    end

    it 'keeps existing stats' do
      red_link.participant_count = 5
      blue_link.participant_count = 7
      experiment.winner = 'blue'

      post "/reopen?experiment=#{experiment.name}"

      expect(red_link.participant_count).to eq(5)
      expect(blue_link.participant_count).to eq(7)
    end
  end

  describe 'reset experiment' do
    let(:event_proc) { -> { post "/reset?experiment=#{experiment.name}" } }
    let(:event) { 'reset' }
    it_behaves_like 'logged events'

    it 'should reset an experiment' do
      red_link.participant_count = 5
      blue_link.participant_count = 7
      experiment.winner = 'blue'

      post "/reset?experiment=#{experiment.name}"

      # hef 2 reload because of memoiza tion
      updated_experiment = Split::ExperimentCatalog.find(experiment.name)

      expect(last_response).to be_redirect

      new_red_count = red_link.participant_count
      new_blue_count = blue_link.participant_count

      expect(new_blue_count).to eq(0)
      expect(new_red_count).to eq(0)
      expect(updated_experiment.winner).to be_nil
    end
  end

  describe 'delete experiment' do
    let(:event_proc) { -> { delete "/experiment?experiment=#{experiment.name}" } }
    let(:event) { 'delete' }
    it_behaves_like 'logged events'

    it 'should delete an experiment' do
      delete "/experiment?experiment=#{experiment.name}"
      expect(last_response).to be_redirect
      expect(Split::ExperimentCatalog.find(experiment.name)).to be_nil
    end
  end

  describe 'set experiment winner' do
    let(:event_proc) { -> { post "/experiment?experiment=#{experiment.name}", alternative: 'red' } }
    let(:event) { 'set_winner' }
    it_behaves_like 'logged events'

    it 'should mark an alternative as the winner' do
      expect(experiment.winner).to be_nil
      post "/experiment?experiment=#{experiment.name}", alternative: 'red'

      # hef 2 reload because of memoization
      updated_experiment = Split::ExperimentCatalog.find(experiment.name)

      expect(last_response).to be_redirect
      expect(updated_experiment.winner.name).to eq('red')
    end
  end

  it 'should display the start date' do
    experiment_start_time = Time.parse('2011-07-07')
    expect(Time).to receive(:now).at_least(:once).and_return(experiment_start_time)
    experiment

    get "/experiments/#{experiment.name}"

    expect(last_response.body).to include('<small>2011-07-07</small>')
  end

  it 'should handle experiments without a start date' do
    experiment_start_time = Time.parse('2011-07-07')
    expect(Time).to receive(:now).at_least(:once).and_return(experiment_start_time)

    Split.redis.hdel(:experiment_start_times, experiment.name)

    get "/experiments/#{experiment.name}"

    expect(last_response.body).to include('<small>Unknown</small>')
  end
end
