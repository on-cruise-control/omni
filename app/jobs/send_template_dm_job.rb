class SendTemplateDmJob < ApplicationJob
  queue_as :default

  MAX_COMMENT_REPLY_RETRIES = 3
  COMMENT_REPLY_RETRY_WAIT = 5.seconds

  def perform(contact_inbox_id, conversation, comment_id, retry_count = 0)
    Rails.logger.info "=================== SendTemplateDmJob START =======comment_id #{comment_id}============"

    contact_inbox = ContactInbox.find_by(id: contact_inbox_id)
    unless contact_inbox
      Rails.logger.error "❌ ContactInbox not found for ID: #{contact_inbox_id}"
      return
    end

    if conversation.nil?
      Rails.logger.error '❌ Conversation is nil'
      return
    end

    account = contact_inbox.inbox.account
    unless account
      Rails.logger.error "❌ Account not found for ContactInbox ID: #{contact_inbox_id}"
      return
    end

    contact = conversation.contact
    inbox = contact_inbox.inbox
    recipient_id = contact.get_source_id(inbox.id) if contact && inbox

    if recipient_id.blank?
      Rails.logger.error "❌ Missing recipient_id for conversation: #{conversation.id}"
      return
    end

    # One template DM per contact per post. Comments arriving together on the same post
    # each enqueue this job; the atomic write (Redis SET NX) lets exactly one job proceed.
    if retry_count.zero?
      dm_lock_key = "template_dm_job_#{contact_inbox.id}_#{contact.id}_#{post_identifier(conversation)}"
      unless Rails.cache.write(dm_lock_key, true, expires_in: 5.minutes, unless_exist: true)
        Rails.logger.info "⏩ Duplicate template DM skipped for contact #{contact.id} on post #{post_identifier(conversation)}"
        return
      end
    end

    comment_text = conversation.messages.first&.content || ''

    lang_code = detect_comment_language(comment_text)

    template_message = I18n.t('dm_template', locale: lang_code)

    comment_reply_text = conversation.messages.outgoing.first&.content
    if comment_reply_text.blank? && retry_count < MAX_COMMENT_REPLY_RETRIES
      self.class.set(wait: COMMENT_REPLY_RETRY_WAIT).perform_later(contact_inbox_id, conversation, comment_id, retry_count + 1)
      return
    end

    template_message = "#{template_message},\n#{comment_reply_text}" if comment_reply_text.present?

    case conversation.additional_attributes['type']
    when 'instagram_comments', 'instagram_dm'
      send_instagram_dm(contact_inbox, recipient_id, template_message, comment_id, conversation)
    when 'facebook_comments', 'facebook_dm', 'feed_comments'
      send_facebook_dm(contact_inbox, recipient_id, template_message, comment_id, conversation)
    else
      Rails.logger.warn "⚠️ Unsupported type for template DM: #{conversation.additional_attributes['type']}"
    end
  end

  private

  # Stable identifier for the post a comment belongs to: IG media id, or FB post id / permalink.
  # Falls back to 'unknown' so DMs still dedupe per contact when the post can't be determined.
  def post_identifier(conversation)
    attrs = conversation.additional_attributes || {}
    attrs['media_id'].presence || attrs['post_id'].presence || attrs['post_url'].presence || 'unknown'
  end

  def channel
    Channel::FacebookPage.find_by(id: contact_inbox.inbox.channel_id)
  end

  def detect_comment_language(text)
    spanish_keywords = /\b(hola|gracias|buenos|dias|lindo|tarde|noche|muy|nuevo|interesad[ao]|buen|auto|este|se|ve|excelente|grande|producto|servicio|trabajo|buena|genial|soy|eres|gusta|tengo|puedo|necesito|deseo|quiero|informacion|detalles|carro|motor|rueda|puerta|ventana|asiento|volante|freno|precio|costo|venta|comprar|vender|oferta|descuento|credito|seguro|garantia|kilometraje|usado|seminuevo|agencia|sedan|hatchback|suv|coupe|convertible|camioneta|pickup|furgoneta|deportivo|estado|condicion|optimo|impecable|danado|roto|accidentado|gps|bluetooth|camara|sensores|alarma|piel|tela|sunroof|color|rojo|azul|verde|negro|blanco|gris|plateado|amarillo|disponible|stock|reservar|cotizar|cuanto|que|como|donde|cuando|tienen|hay|km|millas|gasolina|diesel|electrico|hibrido|automatica|manual|traccion|bonito|elegante|estilo|esto|hermoso|fascina|poderoso|encanta|perfecto|tremendo|pregunta|mensaje|coche|comentario|fenomenal|magnifico|espectacular|fantastico|impresionante|increible|probar|conducir|manejar|velocidad|potencia|consumo|rendimiento|seguridad|confort|lujo|equipamiento|accesorios|llantas|faros|tecnologia|audio|sonido|piloto|crucero|control|clima|asientos|cuero|madera|carbono|edicion|especial|modelo|matricula|revision|mantenimiento|taller|mecanico|presupuesto|financiacion|entrada|cuotas|pago|contado|transferencia|documentacion|papeles|multas|deudas|historial|propietario|particular|profesional|empresa|flota|ocasion|demostracion|catalogo|ficha|tecnica|emisiones|impuesto|circulacion|terceros|robo|incendio|granizo|vidrios|responsabilidad|civil|asistencia|carretera|grua|averia|cobertura|prima|deducible|franquicia|peritaje|chasis|carroceria|pintura|oxido|chocado|reparado|original|piezas|recambios|desguace|despiece|subasta|remate|liquidacion|saldo|existencias|unidades|oportunidad|promocion|campana|rebaja|navidad|reyes|verano|invierno|temporada|outlet|adios|buenas|vale|claro|amigo|amiga|usted|nosotros|vosotros|ellos|ellas|porque|tambien|pero|aunque|entonces|ahora|despues|antes|ayer|hoy|manana|aqui|alla|alli|ese|aquel|mucho|poco|algun|ningun|siempre|nunca|todavia|ya|asi|solo|bien|mal|mas|menos|quien|cual|cuales|cuantos|cuantas|por|para|sobre|favor|ayuda|respuesta|saludos|encantado|placer)\b/ix

    english_keywords = /\b(hi|hello|thanks|thank|please|good|great|awesome|cool|car|cars|truck|suv|convertible|sedan|hatchback|miles|mile|mpg|month|months|year|years|lease|down|payment|cash|credit|warranty|price|cost|sale|buy|sell|offer|discount|information|details|how|what|which|where|when|do|does|is|are|can|could|may|might|want|need|interested|new|used|manual|automatic|hybrid|electric|gas|diesel|color|black|white|silver|blue|green|red|yellow|gray|available|stock|book|quote|deal|financing|installments|mileage|service|test|drive|speed|power|safety|comfort|luxury|features|audio|camera|sensor|leather|fabric|sunroof|control|climate|seats|wood|carbon|model|registration|maintenance|workshop|mechanic|budget|entry|papers|documents|history|owner|company|fleet|demo|catalog|specs|technical|tax|insurance|roadside|coverage|deductible|chassis|body|paint|rust|auction|clearance|outlet|bye|okay|sure|friend|because|also|but|though|then|now|after|before|yesterday|today|tomorrow|here|there|that|much|less|more|who|which|how|many|how|much)\b/i

    spanish_characters = /[áéíóúñü¿¡]/

    text_downcased = (text || '').downcase
    words = text_downcased.scan(/\b[a-záéíóúñü¿¡]+\b/)
    return :en if words.empty?

    # Score keywords
    spanish_count = words.count { |w| w.match?(spanish_keywords) } + (text_downcased.match?(spanish_characters) ? 2 : 0)
    english_count = words.count { |w| w.match?(english_keywords) }

    Rails.logger.info "🌍 Language Detection Scores => ES: #{spanish_count}, EN: #{english_count}"

    # Prefer English on tie or near-tie to avoid false Spanish on short English phrases
    return :es if spanish_count >= english_count + 1

    :en
  end

  def find_existing_template_facebook_dm_conversation(_contact_inbox, contact, inbox, account)
    Conversation.joins(contact_inbox: { contact: :account }, inbox: :account)
                .where(
                  "conversations.contact_id = ? AND conversations.inbox_id = ? AND inboxes.account_id = ? AND conversations.additional_attributes->>'type' = ?",
                  contact.id,
                  inbox.id,
                  account.id,
                  'template_dm'
                )
                .last
  end

  def find_existing_template_insta_dm_conversation(_contact_inbox, contact, inbox, account)
    Conversation.joins(contact_inbox: { contact: :account }, inbox: :account)
                .where(
                  "conversations.contact_id = ? AND conversations.inbox_id = ? AND inboxes.account_id = ? AND conversations.additional_attributes->>'type' = ?",
                  contact.id,
                  inbox.id,
                  account.id,
                  'instagram_dm'
                )
                .last
  end

  def find_or_create_template_facebook_dm_conversation(contact_inbox, contact, inbox, account)
    template_dm_conversation = find_existing_template_facebook_dm_conversation(contact_inbox, contact, inbox, account)

    if template_dm_conversation.nil?
      Rails.logger.info "No existing conversation found, creating a new one for contact #{contact.id} in inbox #{inbox.id}"
      template_dm_conversation = Conversation.create!(
        contact: contact,
        inbox: inbox,
        account: account,
        contact_inbox: contact_inbox,
        additional_attributes: { 'type' => 'template_dm' }
      )
    else
      Rails.logger.info "Found existing conversation #{template_dm_conversation.id} for contact #{contact.id} in inbox #{inbox.id}"
    end

    template_dm_conversation
  end

  def find_or_create_template_insta_dm_conversation(contact_inbox, contact, inbox, account)
    template_dm_conversation = find_existing_template_insta_dm_conversation(contact_inbox, contact, inbox, account)

    if template_dm_conversation.nil?
      Rails.logger.info "No existing conversation found, creating a new one for contact #{contact.id} in inbox #{inbox.id}"
      template_dm_conversation = Conversation.create!(
        contact: contact,
        inbox: inbox,
        account: account,
        contact_inbox: contact_inbox,
        additional_attributes: { 'type' => 'instagram_dm' }
      )
    else
      Rails.logger.info "Found existing conversation #{template_dm_conversation.id} for contact #{contact.id} in inbox #{inbox.id}"
    end

    template_dm_conversation
  end

  def send_facebook_dm(contact_inbox, _recipient_id, template_message, comment_id, comment_conversation)
    channel = contact_inbox.inbox.channel
    access_token = channel.page_access_token
    page_id = channel.page_id
    app_secret = GlobalConfigService.load('FB_APP_SECRET', '')
    app_secret_proof = calculate_app_secret_proof(app_secret, access_token)

    query = { access_token: access_token }
    query[:appsecret_proof] = app_secret_proof if app_secret_proof.present?

    url = "https://graph.facebook.com/v23.0/#{page_id}/messages"

    body = {
      messaging_type: 'RESPONSE',
      recipient: { comment_id: comment_id },
      message: { text: template_message }
    }

    contact = contact_inbox.contact
    inbox = contact_inbox.inbox
    account = inbox.account
    post_id = post_identifier(comment_conversation)

    # Skip if a template DM has already been sent to this contact for this post
    existing_conversation = find_existing_template_facebook_dm_conversation(contact_inbox, contact, inbox, account)
    if dm_already_sent_for_post?(existing_conversation, post_id)
      Rails.logger.info "⏩ Skipping duplicate template DM - already sent to contact #{contact.id} for post #{post_id}"
      return
    end

    template_dm_conversation = find_or_create_template_facebook_dm_conversation(contact_inbox, contact, inbox, account)
    stark_bot = AgentBot.find_by(bot_type: 'stark')

    message = template_dm_conversation.messages.create!(
      content: template_message,
      account: account,
      inbox: inbox,
      sender: stark_bot,
      message_type: :outgoing,
      private: false,
      source_id: 'pending_delivery',
      additional_attributes: { 'delivery_status' => 'sent' }
    )

    response = HTTParty.post(
      url,
      headers: { 'Content-Type' => 'application/json' },
      query: query,
      body: body.to_json
    )

    if response.code != 200 || response['error'].present?
      error = response['error'] || {}
      Messages::StatusUpdateService.new(message, 'failed', "#{error['code']} - #{error['message']}").perform
      Rails.logger.error "❌ Facebook DM Template API error: #{error.presence || response.body}"
      return
    end

    message.update!(source_id: response['message_id'])

    mark_dm_sent_for_post(template_dm_conversation, post_id)

    Rails.logger.info '✅ Facebook Template DM sent successfully'
  end

  def send_instagram_dm(contact_inbox, _recipient_id, template_message, comment_id, comment_conversation)
    channel = contact_inbox.inbox.channel
    access_token = channel.access_token
    page_id = channel.instagram_id

    url = "https://graph.instagram.com/v23.0/#{page_id}/messages"

    body = {
      recipient: { comment_id: comment_id },
      message: { text: template_message }
    }

    contact = contact_inbox.contact
    inbox = contact_inbox.inbox
    account = inbox.account
    post_id = post_identifier(comment_conversation)

    # Skip if a template DM has already been sent to this contact for this post
    existing_conversation = find_existing_template_insta_dm_conversation(contact_inbox, contact, inbox, account)
    if dm_already_sent_for_post?(existing_conversation, post_id)
      Rails.logger.info "⏩ Skipping duplicate template DM - already sent to contact #{contact.id} for post #{post_id}"
      return
    end

    template_dm_conversation = find_or_create_template_insta_dm_conversation(contact_inbox, contact, inbox, account)
    stark_bot = AgentBot.find_by(bot_type: 'stark')

    message = template_dm_conversation.messages.create!(
      content: template_message,
      account: account,
      inbox: inbox,
      sender: stark_bot,
      message_type: :outgoing,
      private: false,
      source_id: 'pending_delivery',
      additional_attributes: { 'delivery_status' => 'sent' }
    )

    response = HTTParty.post(
      url,
      headers: { 'Content-Type' => 'application/json' },
      query: { access_token: access_token },
      body: body.to_json
    )

    if response.code != 200 || response['error'].present?
      error = response['error'] || {}
      Messages::StatusUpdateService.new(message, 'failed', "#{error['code']} - #{error['message']}").perform
      Rails.logger.error "❌ Instagram DM Template API error: #{error.presence || response.body}"
      return
    end

    message.update!(source_id: response['message_id'])

    mark_dm_sent_for_post(template_dm_conversation, post_id)

    Rails.logger.info '✅ Instagram Template DM sent successfully'
  end

  # Template DM conversations track which posts they've already replied to in
  # additional_attributes['dm_sent_post_ids'] (one entry per post).
  def dm_already_sent_for_post?(conversation, post_id)
    return false if conversation.nil?

    Array(conversation.additional_attributes['dm_sent_post_ids']).include?(post_id)
  end

  def mark_dm_sent_for_post(conversation, post_id)
    conversation.reload
    sent_post_ids = Array(conversation.additional_attributes['dm_sent_post_ids']) | [post_id]
    conversation.update!(
      additional_attributes: conversation.additional_attributes.merge('dm_sent_post_ids' => sent_post_ids)
    )
  end

  def calculate_app_secret_proof(app_secret, access_token)
    return nil if app_secret.blank? || access_token.blank?

    OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha256'), app_secret, access_token)
  end
end
