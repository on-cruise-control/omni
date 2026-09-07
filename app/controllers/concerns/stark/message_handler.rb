require 'open-uri'

module Stark
  module MessageHandler
    extend ActiveSupport::Concern

    AI_LOOP_LABEL = 'ai_loop_detected'.freeze

    def handle_response(response)
      if response.is_a?(Hash) && response['session_status'] == AI_LOOP_LABEL
        flag_ai_loop_detected(current_conversation)
        return
      end

      return unless response_valid?(response)

      if response['is_spam']
        current_conversation.update!(is_spam: true)

        if response['content'].present? || (response['attachments'].is_a?(Array) && response['attachments'].any?)
          create_bot_response_message(current_conversation, response['content'], response['attachments'], response['metadata'],
                                      is_deferred_spam_reply: true)
        end
        return
      end

      has_content = response['content'].present? || (response['attachments'].is_a?(Array) && response['attachments'].any?)
      if response['should_send_reply'] != false && has_content
        create_bot_response_message(current_conversation, response['content'], response['attachments'], response['metadata'])
      end
      process_action(event_data[:message], response['action']) if response['action'].present?
    end

    def create_bot_response_message(conversation, contents, attachments = nil, metadata = {}, is_deferred_spam_reply: false)
      contents = Array(contents)
      if (instagram_channel?(conversation) || facebook_channel?(conversation)) && attachments.is_a?(Array) && attachments.any?

        # 1. Send all content chunks
        contents.each do |content|
          next if content.blank?

          conversation.messages.create!(
            content: content,
            message_type: :outgoing,
            account_id: conversation.account_id,
            inbox_id: conversation.inbox_id,
            sender: agent_bot,
            metadata: metadata,
            private: is_deferred_spam_reply,
            additional_attributes: is_deferred_spam_reply ? { deferred_spam_reply: true } : {}
          )
        end

        # 2. For each attachment: image then title
        attachments.each do |attachment|
          url = attachment.is_a?(Hash) ? (attachment['url'] || attachment[:url]) : attachment
          title = attachment.is_a?(Hash) ? (attachment['content'] || attachment[:content]) : nil
          next if url.blank?

          file = URI.open(url)
          filename = File.basename(URI.parse(url).path)

          blob = ActiveStorage::Blob.create_and_upload!(
            io: file,
            filename: filename,
            content_type: file.content_type
          )

          # (a) Image message (no content)
          image_message = conversation.messages.new(
            message_type: :outgoing,
            account_id: conversation.account_id,
            inbox_id: conversation.inbox_id,
            sender: agent_bot,
            private: is_deferred_spam_reply,
            additional_attributes: bypass_attributes(is_deferred_spam_reply, { 'sent_image': true })
          )
          image_message.attachments.new(
            account_id: conversation.account_id,
            external_url: url,
            file: blob
          )
          image_message.save!

          # (b) Title message (text only), after a small delay
          next unless title.present?

          conversation.messages.create!(
            content: title,
            message_type: :outgoing,
            account_id: conversation.account_id,
            inbox_id: conversation.inbox_id,
            sender: agent_bot,
            private: is_deferred_spam_reply,
            additional_attributes: is_deferred_spam_reply ? { deferred_spam_reply: true } : {}
          )
        end

      elsif widget_channel?(conversation) && attachments.is_a?(Array) && attachments.any?
        contents.each do |content|
          create_text_message(conversation, content, metadata, is_deferred_spam_reply) if content.present?
        end
        create_cards_message(conversation, attachments, metadata, is_deferred_spam_reply)

      else
        contents.each do |content|
          create_text_message(conversation, content, metadata, is_deferred_spam_reply) if content.present?
        end
        if attachments.is_a?(Array) && attachments.any?
          create_attachment_messages(conversation, attachments, metadata, is_deferred_spam_reply)
        else
          Rails.logger.info('[Cards] No attachments present, skipping cards message')
        end
      end
    end

    def bypass_attributes(is_deferred_spam_reply, attrs)
      is_deferred_spam_reply ? attrs.merge({ deferred_spam_reply: true }) : attrs
    end

    def response_valid?(response)
      attachments_present = response['attachments'].is_a?(Array) && response['attachments'].any?
      response.is_a?(Hash) && (response['content'].present? || response['action'].present? || attachments_present)
    end

    private

    def flag_ai_loop_detected(conversation)
      return if conversation.additional_attributes&.dig('session_status') == AI_LOOP_LABEL

      label = Label.find_or_create_by!(account: conversation.account, title: AI_LOOP_LABEL)
      labels = conversation.label_list.include?(label.title) ? conversation.label_list : conversation.label_list + [label.title]

      conversation.update!(
        label_list: labels,
        should_send_reply: false,
        additional_attributes: (conversation.additional_attributes || {}).merge('session_status' => AI_LOOP_LABEL)
      )
    end

    def duplicate_outgoing?(conversation, content: nil, cards_items: nil)
      scope = conversation.messages
                          .outgoing
                          .where(sender: agent_bot)
                          .where('created_at >= ?', 2.minutes.ago)

      if cards_items
        scope.where(content_type: :cards)
             .any? { |m| m.content_attributes&.dig('items') == cards_items }
      else
        return false if content.blank?

        scope.where(content: content).exists?
      end
    end

    def create_text_message(conversation, content, metadata = {}, is_deferred_spam_reply = false)
      return if duplicate_outgoing?(conversation, content: content)

      conversation.messages.create!(
        content: content,
        message_type: :outgoing,
        account_id: conversation.account_id,
        inbox_id: conversation.inbox_id,
        sender: agent_bot,
        metadata: metadata,
        private: is_deferred_spam_reply,
        additional_attributes: is_deferred_spam_reply ? { deferred_spam_reply: true } : {}
      )
    end

    def create_cards_message(conversation, attachments, metadata = {}, is_deferred_spam_reply = false)
      items = attachments.map do |attachment|
        url        = attachment.is_a?(Hash) ? (attachment['url']        || attachment[:url])        : attachment
        title      = attachment.is_a?(Hash) ? (attachment['content']    || attachment[:content])    : nil
        vehicle_id = attachment.is_a?(Hash) ? (attachment['vehicle_id'] || attachment[:vehicle_id]) : nil
        action_type    = vehicle_id.present? ? 'view_vehicle' : 'postback'
        action_payload = vehicle_id.presence || title
        { title: title, description: '', media_url: url, vehicle_id: vehicle_id,
          actions: [{ text: 'View Details', type: action_type, payload: action_payload }] }
      end

      return if duplicate_outgoing?(conversation, cards_items: items)

      conversation.messages.create!(
        content_type: :cards,
        content_attributes: { items: items },
        message_type: :outgoing,
        account_id: conversation.account_id,
        inbox_id: conversation.inbox_id,
        sender: agent_bot,
        metadata: metadata,
        private: is_deferred_spam_reply,
        additional_attributes: is_deferred_spam_reply ? { deferred_spam_reply: true } : {}
      )
    end

    def create_attachment_messages(conversation, attachments, metadata = {}, is_deferred_spam_reply = false)
      attachments.each do |attachment|
        url = attachment.is_a?(Hash) ? (attachment['url'] || attachment[:url]) : attachment
        content = attachment.is_a?(Hash) ? (attachment['content'] || attachment[:content]) : nil
        next if url.blank?

        begin
          file = URI.open(url)
        rescue OpenURI::HTTPError, StandardError => e
          Rails.logger.warn "Failed to download attachment from #{url}: #{e.message}"
          next
        end

        filename = File.basename(URI.parse(url).path)

        blob = ActiveStorage::Blob.create_and_upload!(
          io: file,
          filename: filename,
          content_type: file.content_type
        )

        message = conversation.messages.new(
          content: content,
          message_type: :outgoing,
          account_id: conversation.account_id,
          inbox_id: conversation.inbox_id,
          sender: agent_bot,
          metadata: metadata,
          private: is_deferred_spam_reply,
          additional_attributes: is_deferred_spam_reply ? { deferred_spam_reply: true } : {}
        )

        message.attachments.new(
          account_id: message.account_id,
          external_url: url,
          file: blob
        )

        message.save!
      end
    end

    def instagram_channel?(conversation)
      conversation.inbox.platform_name == 'Instagram'
    end

    def facebook_channel?(conversation)
      conversation.inbox.platform_name == 'Facebook'
    end

    def widget_channel?(conversation)
      conversation.inbox.channel_type == 'Channel::WebWidget'
    end
  end
end
