module Stark
  class SessionStatusService
    def initialize(conversation)
      @conversation = conversation
    end

    def update_status(status)
      return { status: 'error', message: 'Missing conversation' } if @conversation.blank?
      return { status: 'error', message: 'Missing Stark API base URL' } if stark_session_status_url.blank?

      response = HTTParty.put(
        stark_session_status_url,
        body: { status: status }.to_json,
        headers: build_request_headers,
        timeout: 30
      )

      Rails.logger.info("Stark SessionStatus response for conversation #{@conversation.id}: #{response.body}")

      parsed_response = JSON.parse(response.body)
      status_code = parsed_response.dig('metadata', 'status_code').to_i

      if status_code == 200
        { status: 'success' }
      else
        error_message = parsed_response.dig('body', 'message') || 'Failed to update Stark session status'
        Rails.logger.error("Stark SessionStatus update failed for conversation #{@conversation.id}: #{error_message}")
        { status: 'error', message: error_message }
      end
    rescue JSON::ParserError
      Rails.logger.error("Stark SessionStatus invalid response for conversation #{@conversation.id}: #{response&.body}")
      { status: 'error', message: 'Invalid response format from Stark server' }
    rescue StandardError => e
      Rails.logger.error("Stark SessionStatus error for conversation #{@conversation.id}: #{e.message}")
      { status: 'error', message: e.message }
    end

    private

    def build_request_headers
      {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{ENV.fetch('STARK_API_KEY')}"
      }
    end

    def stark_session_status_url
      outgoing_url = AgentBot.where(bot_type: 'stark').last&.outgoing_url
      return if outgoing_url.blank?

      URI.join(outgoing_url, "/api/v1/session/#{@conversation.id}/status").to_s
    rescue URI::InvalidURIError => e
      Rails.logger.error("Invalid Stark outgoing URL for conversation #{@conversation.id}: #{e.message}")
      nil
    end
  end
end
