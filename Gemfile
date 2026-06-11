# frozen_string_literal: true

source 'https://rubygems.org'

group :test do
  transport_path = ENV.fetch('LEGION_TRANSPORT_PATH', File.expand_path('../../legion-transport', __dir__))
  gem 'legion-transport', path: transport_path if File.directory?(transport_path)
  # lex-llm resolved from rubygems (>= 0.5.0) via gemspec - no local path dep
end

gemspec

group :development do
  gem 'bundler', '>= 2.0'
  gem 'rake', '>= 13.0'
  gem 'rspec', '~> 3.12'
  gem 'rubocop', '>= 1.0'
  gem 'rubocop-performance'
  gem 'rubocop-rake', '>= 0.6'
  gem 'rubocop-rspec'
end
