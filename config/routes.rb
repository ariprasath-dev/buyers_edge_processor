Rails.application.routes.draw do
  # Root path
  root 'journal_entries#index'

  # Journal Entry processing routes
  resources :journal_entries, only: [:index, :create] do
  collection do
    get :result
    get 'download/*filename', action: :download, as: :download
  end
end

  # API endpoints
  namespace :api do
    namespace :v1 do
      resources :journal_entries, only: [:create] do
        collection do
          get 'download/*filename', action: :download
        end
      end
    end
  end

  # Health check
  get 'health', to: 'health#index'
  
get 'help', to: 'help#index'
end