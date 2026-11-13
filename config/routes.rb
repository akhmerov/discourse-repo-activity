# frozen_string_literal: true

DiscourseRepoActivity::Engine.routes.draw do
  get "/overview" => "overview#index"
  post "/hooks/:public_id" => "hooks#create"
  get "/channels/:channel_id" => "channels#show"
  put "/channels/:channel_id/read" => "channels#read"
  get "/channels/:channel_id/connections" => "connections#index"
  post "/channels/:channel_id/connections" => "connections#create"
  put "/channels/:channel_id/connections/:id" => "connections#update"
  get "/channels/:channel_id/connections/:id/secret" => "connections#secret"
  post "/channels/:channel_id/connections/:id/rotate" => "connections#rotate"
  delete "/channels/:channel_id/connections/:id" => "connections#destroy"
end
