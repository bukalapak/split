# frozen_string_literal: true
module Split
  class Protor
    class << self
      def counter(*args)
        return unless protor
        protor.counter(*args)
      end

      private

      def protor
        ::Split.configuration.protor
      end
    end
  end
end
