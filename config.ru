require 'rubygems'
require 'bundler'

Bundler.require

require './snet2ig'
run Sinatra::Application
