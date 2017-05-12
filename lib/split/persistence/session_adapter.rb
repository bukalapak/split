# frozen_string_literal: true

module Split
  module Persistence
    class SessionAdapter
      def initialize(context)
        @session = context.session
        @session[:split] ||= {}
      end

      def [](key)
        @session[:split][key]
      end

      def multi_get(*keyss)
        keyss.map { |key| @session[:split][key] }
      end

      def []=(key, value)
        @session[:split][key] = value
      end

      # TODO: do in atomic fashion like redis' setnx
      # (or another way to handle race condition)
      def setnx(key, value)
        self[key] = value unless self[key]
      end

      def delete(*keyss)
        keyss.each do |key|
          @session[:split].delete(key)
        end
      end

      def keys
        @session[:split].keys
      end
    end
  end
end
