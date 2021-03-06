require 'faye/websocket'
require 'multi_json'

require 'lita/adapters/slack/api'
require 'lita/adapters/slack/event_loop'
require 'lita/adapters/slack/im_mapping'
require 'lita/adapters/slack/message_handler'
require 'lita/adapters/slack/room_creator'
require 'lita/adapters/slack/user_creator'

module Lita
  module Adapters
    class Slack < Adapter
      # @api private
      class RTMConnection
        MAX_MESSAGE_BYTES = 16_000

        class << self
          def build(robot, config)
            team_data = API.new(config).rtm_start
            new(robot, config, team_data)
          end
        end

        def initialize(robot, config, team_data)
          @robot = robot
          @config = config
          Lita.logger.debug("Before IMMapping")
          @im_mapping = IMMapping.new(API.new(config), team_data.ims)
          Lita.logger.debug("After IMMapping")
          @websocket_url = team_data.websocket_url
          @robot_id = team_data.self.id

          @slack_users = team_data.users
          @slack_channels = team_data.channels
        end

        def im_for(user_id)
          im_mapping.im_for(user_id)
        end

        def run(queue = nil, options = {})
          EventLoop.run do
            log.debug("Connecting to the Slack Real Time Messaging API.")
            @websocket = Faye::WebSocket::Client.new(
              websocket_url,
              nil,
              websocket_options.merge(options)
            )

            websocket.on(:open) do
              log.debug("Connected to the Slack Real Time Messaging API.")
              yield if block_given?
              log.debug("Inserting #{slack_users.size} users")
              UserCreator.create_users(slack_users, robot, robot_id)
              log.debug("Inserting #{slack_channels.size} channels")
              RoomCreator.create_rooms(slack_channels, robot)
              log.debug("Done inserting channels.")
            end
            websocket.on(:message) { |event| receive_message(event) }
            websocket.on(:close) do |event|
              log.info("Disconnected from Slack.")
              log.info(event.code)
              log.info(event.reason)
              EventLoop.safe_stop
            end
            websocket.on(:error) { |event| log.debug("WebSocket error: #{event.message}") }

            queue << websocket if queue
          end
        end

        def send_messages(channel, strings)
          strings.each do |string|
            EventLoop.defer { websocket.send(safe_payload_for(channel, string)) }
          end
        end

        def shut_down
          if websocket && EventLoop.running?
            log.debug("Closing connection to the Slack Real Time Messaging API.")
            websocket.close
          end

          EventLoop.safe_stop
        end

        private

        attr_reader :config
        attr_reader :im_mapping
        attr_reader :robot
        attr_reader :robot_id
        attr_reader :websocket
        attr_reader :websocket_url
        attr_reader :slack_users
        attr_reader :slack_channels

        def log
          Lita.logger
        end

        def payload_for(channel, string)
          MultiJson.dump({
            id: 1,
            type: 'message',
            text: string,
            channel: channel
          })
        end

        def receive_message(event)
          data = MultiJson.load(event.data)

          EventLoop.defer { MessageHandler.new(robot, robot_id, data).handle }
        end

        def safe_payload_for(channel, string)
          payload = payload_for(channel, string)

          if payload.size > MAX_MESSAGE_BYTES
            raise ArgumentError, "Cannot send payload greater than #{MAX_MESSAGE_BYTES} bytes."
          end

          payload
        end

        def websocket_options
          options = { ping: 10 }
          options[:proxy] = { :origin => config.proxy } if config.proxy
          options
        end

      end
    end
  end
end
