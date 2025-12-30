class HealthController < ApplicationController
  skip_before_action :verify_authenticity_token

  def index
    render json: {
      status: 'ok',
      timestamp: Time.current.iso8601,
      version: '1.0.0'
    }
  end
end