# frozen_string_literal: true

%w[weighted_sample whiplash].each do |f|
  require "split/algorithms/#{f}"
end
