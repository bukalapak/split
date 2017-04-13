# frozen_string_literal: true

require 'sinatra/base'
require 'split'
require 'bigdecimal'
require 'split/dashboard/helpers'

module Split
  class Dashboard < Sinatra::Base
    dir = File.dirname(File.expand_path(__FILE__))

    set :views, "#{dir}/dashboard/views"
    set :public_folder, "#{dir}/dashboard/public"
    set :static, true
    set :method_override, true

    helpers Split::DashboardHelpers

    get '/' do
      # Display experiments without a winner at the top of the dashboard
      @experiments = Split::ExperimentCatalog.all_active_first

      erb :index
    end

    get '/experiments/:name' do
      @experiment = load_experiment(params[:name])
      redirect url('/') unless @experiment

      erb :'experiments/show'
    end

    post '/force_alternative' do
      Split::User.new(self)[params[:experiment]] = params[:alternative]
      redirect url("/experiments/#{params[:experiment]}")
    end

    post '/experiment' do
      @experiment = load_experiment(params[:experiment])
      @alternative = Split::Alternative.new(params[:alternative], params[:experiment])
      @experiment.winner = @alternative.name

      log_action(@experiment, 'set_winner')
      redirect url("/experiments/#{params[:experiment]}")
    end

    post '/start' do
      @experiment = load_experiment(params[:experiment])
      @experiment.start

      log_action(@experiment, 'start')
      redirect url("/experiments/#{params[:experiment]}")
    end

    post '/reset' do
      @experiment = load_experiment(params[:experiment])
      @experiment.reset

      log_action(@experiment, 'reset')
      redirect url("/experiments/#{params[:experiment]}")
    end

    post '/reopen' do
      @experiment = load_experiment(params[:experiment])
      @experiment.delete_winner

      log_action(@experiment, 'reopen')
      redirect url("/experiments/#{params[:experiment]}")
    end

    delete '/experiment' do
      @experiment = load_experiment(params[:experiment])
      @experiment.delete

      log_action(@experiment, 'delete')
      redirect url("/experiments/#{params[:experiment]}")
    end

    private

    def load_experiment(experiment_name)
      experiment = ::Split::ExperimentCatalog.find(experiment_name)
      experiment.load_from_redis unless ::Split.configuration.experiment_for(experiment_name)
      experiment
    end

    def log_action(experiment, event)
      Split.configuration.logger_proc.call(logger, experiment.name, event)
    end

    def logger
      Split.configuration.logger
    end
  end
end
