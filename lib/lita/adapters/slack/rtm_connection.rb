require 'eventmachine'
require 'faye/websocket'
require 'multi_json'

require 'lita/adapters/slack/api'
require 'lita/adapters/slack/im_mapping'
require 'lita/adapters/slack/message_handler'
require 'lita/adapters/slack/user_creator'

module Lita
  module Adapters
    class Slack < Adapter
      class RTMConnection
        class << self
          def build(token)
            RTMConnection.new(token, API.new(token).rtm_start)
          end
        end

        def initialize(token, data)
          @im_mapping = IMMapping.new(token, data.ims)
          @websocket_url = data.websocket_url

          UserCreator.create_users(data.users)
        end

        def im_for(user_id)
        end

        def run
          EM.run do
            log.debug("Connecting to the Slack Real Time Messaging API.")
            @websocket = Faye::WebSocket::Client.new(url, nil, ping: 10)

            websocket.on(:open) { log.debug("Connected to the Slack Real Time Messaging API.") }
            websocket.on(:message) { |event| receive_message(event) }
            websocket.on(:close) { log.info("Disconnected from Slack.") }
            websocket.on(:error) { |event| log.debug("WebSocket error: #{event.message}") }
          end
        end

        def send_messages(channel, strings)
          strings.each do |string|
            ensure_safe_message_length(string)

            websocket.send MultiJson.dump({
              id: 1,
              type: 'message',
              text: string,
              channel: channel
            })
          end
        end

        def shut_down
          if websocket
            log.debug("Closing connection to the Slack Real Time Messaging API.")
            websocket.close
          end

          EM.stop if EM.reactor_running?
        end

        private

        attr_reader :websocket
        attr_reader :websocket_url

        def ensure_safe_message_length(string)
          if string.size > max_message_characters
            raise ArgumentError,
              "Cannot send message greater than #{max_message_characters} characters: #{string}"
          end
        end

        def log
          Lita.logger
        end

        def max_message_characters
          4000
        end

        def receive_message(event)
          data = MultiJson.load(event.data)

          MessageHandler.new(robot, data).handle
        end
      end
    end
  end
end