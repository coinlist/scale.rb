module Scale
  module Types
    class MetadataV1
      include Base
      attr_accessor :call_index, :event_index

      def initialize(value)
        @call_index = {}
        @event_index = {}
        super(value)
      end

      def self.decode(scale_bytes)
        modules = Scale::Types.get("Vec<MetadataV1Module>").decode(scale_bytes).value

        value = {
          magicNumber: 1_635_018_093,
          metadata: {
            version: 1,
            modules: modules.map(&:value)
          }
        }

        result = MetadataV1.new(value)

        call_module_index = 0
        event_module_index = 0

        modules.map(&:value).each do |m|
          if m[:calls]
            m[:calls].each_with_index do |call, index|
              call[:lookup] = "%02x%02x" % [call_module_index, index]
              result.call_index[call[:lookup]] = [m, call]
            end
            call_module_index += 1
          end

          if m[:events]
            m[:events].each_with_index do |event, index|
              event[:lookup] = "%02x%02x" % [event_module_index, index]
              result.event_index[event[:lookup]] = [m, event]
            end
            event_module_index += 1
          end
        end

        result
      end
    end

    class MetadataV1Module
      include Base
      def self.decode(scale_bytes)
        name = String.decode(scale_bytes).value
        prefix = String.decode(scale_bytes).value

        result = {
          name: name,
          prefix: prefix
        }

        has_storage = Bool.decode(scale_bytes).value
        if has_storage
          storages = Scale::Types.get("Vec<MetadataV1ModuleStorage>").decode(scale_bytes).value
          result[:storage] = storages.map(&:value)
        end

        has_calls = Bool.decode(scale_bytes).value
        if has_calls
          calls = Scale::Types.get("Vec<MetadataModuleCall>").decode(scale_bytes).value
          result[:calls] = calls.map(&:value)
        end

        has_events = Bool.decode(scale_bytes).value
        if has_events
          events = Scale::Types.get("Vec<MetadataModuleEvent>").decode(scale_bytes).value
          result[:events] = events.map(&:value)
        end

        MetadataModule.new(result)
      end
    end

    class MetadataV1ModuleStorage
      include Base

      def self.decode(scale_bytes)
        name = Bytes.decode(scale_bytes).value
        enum = {
          "type" => "enum",
          "value_list" => ["Optional", "Default"]
        }
        modifier = Scale::Types.get(enum).decode(scale_bytes).value

        is_key_value = Bool.decode(scale_bytes).value

        if is_key_value
          type = {
            Map: {
              key: Bytes.decode(scale_bytes).value,
              value: Bytes.decode(scale_bytes).value
            }
          }
        else
          type = {
            Plain: Bytes.decode(scale_bytes).value
          }
        end

        fallback = Hex.decode(scale_bytes).value
        docs = Scale::Types.get("Vec<Bytes>").decode(scale_bytes).value.map(&:value)

        MetadataV1ModuleStorage.new({
          name: name,
          modifier: modifier,
          type: type,
          fallback: fallback,
          documentation: docs
        })
      end
    end

  end
end
