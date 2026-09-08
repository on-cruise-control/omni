class Integrations::Stark::ProcessorService < Integrations::BotProcessorService
  include Stark::ConversationStatusManager
  include Stark::ApiHandler
  include Stark::MessageHandler
  include Stark::Validator

  pattr_initialize [:event_name!, :hook!, :event_data!]

  def perform
    return unless can_process_message?

    process_conversation
  rescue StandardError => e
    ChatwootExceptionTracker.new(e, account: agent_bot.account).capture_exception
  end

  private

  def should_run_processor?(message)
    # Don't process messages on spam conversations
    return false if current_conversation.is_spam
    return false if current_conversation.is_blacklisted
    return false if current_conversation.additional_attributes&.dig('session_status') == Stark::MessageHandler::AI_LOOP_LABEL

    # Primary check: if conversation is assigned, don't process regardless of status
    return false if current_conversation.assignee_id.present?

    # Only send Stark's response when Stark sent the last relevant message
    return false unless last_message_allows_stark_reply?(message)

    # Secondary checks from parent class
    return false if message.private?
    return false unless processable_message?(message)

    true
  end

  def last_message_allows_stark_reply?(current_message)
    return true if current_message.instagram_story_mention?

    last_relevant = last_relevant_message_before(current_message)

    return true if last_relevant.blank?

    return true if last_relevant.sender == agent_bot

    if (last_relevant.sent? || last_relevant.delivered? || last_relevant.read?) && last_relevant.created_at >= 24.hours.ago
      return true if unassigned_after?(last_relevant)

      return false
    end

    true
  end

  def unassigned_after?(message)
    current_conversation.messages
                        .where(message_type: :activity)
                        .where('created_at > ?', message.created_at)
                        .where('content LIKE ?', '%Conversation unassigned by%')
                        .exists?
  end

  def last_relevant_message_before(current_message)
    current_conversation.messages
                        .outgoing
                        .where.not(id: current_message.id)
                        .where('created_at <= ?', current_message.created_at)
                        .reorder(created_at: :desc)
                        .find { |msg| relevant_message?(msg) }
  end

  def relevant_message?(message)
    return false if message.failed?
    return false if message.private?
    return false unless message.sent? || message.delivered? || message.read?
    return false if message.template? || message.activity?
    return false if message.instagram_story_mention?

    true
  end

  def process_conversation
    return unless should_run_processor?(event_data[:message])
    return if handle_missing_dealership_id
    return if event_data[:message].content.blank? && !message_has_image?(event_data[:message])

    process_stark_response
  end

  def process_stark_response
    # Double-check assignment before making API call (conversation might have been assigned since initial check)
    current_conversation.reload
    return if current_conversation.assignee_id.present?

    # return unless current_conversation.pending?

    response = get_stark_response(current_conversation, event_data[:message].content, event_data[:message])
    return if response.nil? # Response is nil if there was an error (already handled by StarkRetryable)

    current_conversation.update!(
      stop_follow_up: response['stop_follow_up'],
      should_send_reply: response['should_send_reply'].nil? || response['should_send_reply']
    )
    schedule_booking_follow_up if response['is_booking_created']
    handle_response(response)
  end

  def handle_missing_dealership_id
    return false if current_conversation.account&.dealership_id.present?

    mark_conversation_open
    true
  end

  def schedule_booking_follow_up
    delay_hours = GlobalConfig.get_value('BOOKING_FOLLOW_UP_DELAY_HOURS').to_i
    delay_hours = 22 if delay_hours <= 0

    jid = Conversations::BookingFollowUpJob.set(wait: delay_hours.hours)
                                           .perform_later(current_conversation.id)
                                           .provider_job_id
    current_conversation.update_column(:booking_follow_up_jid, jid)
  end

  def current_conversation
    @current_conversation ||= event_data[:message].conversation
  end

  def hook
    @hook ||= agent_bot
  end

  def agent_bot
    @agent_bot ||= hook
  end
end
