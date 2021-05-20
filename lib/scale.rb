require "scale/version"

require "common"

require "json"
require "singleton"

require "scale/base"
require "scale/types"
require "scale/block"
require "scale/trie"
require "scale/type_builder"

require "metadata/metadata"
require "metadata/metadata_v0"
require "metadata/metadata_v1"
require "metadata/metadata_v2"
require "metadata/metadata_v3"
require "metadata/metadata_v4"
require "metadata/metadata_v5"
require "metadata/metadata_v6"
require "metadata/metadata_v7"
require "metadata/metadata_v8"
require "metadata/metadata_v9"
require "metadata/metadata_v10"
require "metadata/metadata_v11"
require "metadata/metadata_v12"

require "substrate_client"
require "logger"
require "helper"

class String
  def upcase_first
    self.sub(/\S/, &:upcase)
  end

  def camelize2
    self.split('_').collect(&:upcase_first).join
  end

  def underscore2
    self.gsub(/::/, '/').
    gsub(/([A-Z]+)([A-Z][a-z])/,'\1_\2').
    gsub(/([a-z\d])([A-Z])/,'\1_\2').
    tr("-", "_").
    downcase
  end
end

module Scale
  class Error < StandardError; end

  class TypeRegistry
    include Singleton

    # init by load, and will not change
    attr_reader :spec_name, :types
    attr_reader :versioning, :custom_types # optional

    # will change by different spec version
    attr_accessor :spec_version # optional
    attr_accessor :metadata

    def load(spec_name: nil, custom_types: nil)
      @spec_name = nil
      @types = nil
      @versioning = nil
      @custom_types = nil

      default_types, _, _ = load_chain_spec_types("default")

      if spec_name
        begin
          @spec_name = spec_name
          spec_types, @versioning, @spec_version = load_chain_spec_types(spec_name)
          @types = default_types.merge(spec_types)
        rescue => ex
          puts "There is no types json file named #{spec_name}"
          @types = default_types
        end
      else
        @spec_name = "default"
        @types = default_types
      end

      self.custom_types = custom_types
      true
    end

    def get(type_name)
      all_types = self.all_types
      type = type_traverse(type_name, all_types)

      Scale::Types.constantize(type)
    end

    def custom_types=(custom_types)
      @custom_types = custom_types.stringify_keys if (not custom_types.nil?) && custom_types.class.name == "Hash"
    end

    def all_types
      all_types = {}.merge(@types)

      if @spec_version && @versioning
        @versioning.each do |item|
          if @spec_version >= item["runtime_range"][0] && 
              ( item["runtime_range"][1].nil? || @spec_version <= item["runtime_range"][1] )
            all_types.merge!(item["types"])
          end
        end
      end

      all_types.merge!(@custom_types) if @custom_types
      all_types
    end

    def check_types
      self.all_types.keys.each do |key|
        begin
          type = self.get(key)
        rescue => ex
          puts "[[ERROR]] #{key}: #{ex}"
        end
      end
      ""
    end

    private

      def load_chain_spec_types(spec_name)
        file = File.join File.expand_path("../..", __FILE__), "lib", "type_registry", "#{spec_name}.json"
        json_string = File.open(file).read
        json = JSON.parse(json_string)

        runtime_id = json["runtime_id"]

        [json["types"], json["versioning"], runtime_id]
      end

      def type_traverse(type, types)
        type = rename(type) if type.class == ::String
        if types.has_key?(type) && types[type] != type
          type_traverse(types[type], types)
        else
          type
        end
      end
  end

  # TODO: == implement

  class Bytes
    attr_reader :data, :bytes
    attr_reader :offset

    def initialize(data)
      if (data.class == Array) && data.is_byte_array?
        @bytes = data
      elsif (data.class == String) && data.start_with?("0x") && (data.length % 2 == 0)
        arr = data[2..].scan(/../).map(&:hex)
        @bytes = arr
      else
        raise "Provided data is not valid"
      end

      @data = data
      @offset = 0
    end

    def reset_offset
      @offset = 0
    end

    def get_next_bytes(length)
      result = @bytes[@offset...@offset + length]
      if result.length < length
        str = @data[(2 + @offset * 2)..]
        str = str.length > 40 ? (str[0...40]).to_s + "..." : str
        raise "No enough data: #{str}, expect length: #{length}, but #{result.length}" 
      end
      @offset += length
      result
    rescue RangeError => ex
      puts "length: #{length}"
      puts ex.message
      puts ex.backtrace
    end

    def get_remaining_bytes
      @bytes[offset..]
    end

    def to_hex_string
      @bytes.bytes_to_hex
    end

    def to_bin_string
      @bytes.bytes_to_bin
    end

    def to_ascii 
      @bytes[0...offset].pack("C*") + "<================================>" + @bytes[offset..].pack("C*")
    end

    def ==(other)
      bytes == other.bytes && offset == other.offset
    end

    def to_s
      green(@bytes[0...offset].bytes_to_hex) + yellow(@bytes[offset..].bytes_to_hex[2..])
    end
  end

  class TypesLoader
    def self.load(filename)
      path = File.join File.dirname(__FILE__), "types", filename
      content = File.open(path).read
      result = JSON.parse content

      types = result["default"]
      types.each do |name, body|
        if body.class == String
          target_type = "Scale::Types::#{body}"
          klass = Class.new(target_type.constantize2) do
          end
        elsif body.class == Hash
          if body["type"] == "struct"
            struct_params = {}
            body["type_mapping"].each do |mapping|
              struct_params[mapping[0].to_sym] = mapping[1]
            end
            klass = Class.new do
            end
            klass.send(:include, Scale::Types::Struct)
            klass.send(:items, struct_params)
            Scale::Types.const_set name, klass
          elsif body["type"] = "enum"
            klass = Class.new do
            end
            klass.send(:include, Scale::Types::Enum)
            if body["type_mapping"]
              struct_params = {}
              body["type_mapping"].each do |mapping|
                struct_params[mapping[0].to_sym] = mapping[1]
              end
              klass.send(:items, struct_params)
            else
              klass.send(:values, body["value_list"])
            end
            Scale::Types.const_set name, klass
          end
        end
      end
    end
  end

  module Types
    class << self
      attr_accessor :debug
    end
    
    def self.list
      TypeRegistry.instance.types
    end

    def self.get(type_name)
      type = TypeRegistry.instance.get(type_name)
      raise "Type '#{type_name}' not exist" if type.nil?
      type
    end

    def self.constantize(type)
      if type.class == ::String
        type_of(type.strip)
      else
        if type["type"] == "enum" && type.has_key?("type_mapping")
          type_of("Enum", type["type_mapping"].to_h)
        elsif type["type"] == "enum" && type.has_key?("value_list")
          type_of("Enum", type["value_list"])
        elsif type["type"] == "struct"
          type_of("Struct", type["type_mapping"].to_h)
        elsif type["type"] == "set"
          type_of("Set", type["value_list"])
        end
      end
    end

    # class TestArray
    #   include Array
    #   inner_type "Compact"
    #   length 2
    # end
    def self.type_of(type_string, values = nil)
      if type_string.end_with?(">")
        type_strs = type_string.scan(/^([^<]*)<(.+)>$/).first
        type_str = type_strs.first
        inner_type_str = type_strs.last

        if type_str == "Vec"
          name = "#{type_str}<#{inner_type_str.camelize2}>"
          name = fix(name)

          if !Scale::Types.const_defined?(name)
            klass = Class.new do
              include Scale::Types::Vec
              inner_type inner_type_str
            end
            Scale::Types.const_set name, klass
          else
            Scale::Types.const_get name
          end
        elsif type_str == "Option"
          name = "#{type_str}<#{inner_type_str.camelize2}>"
          name = fix(name)

          if !Scale::Types.const_defined?(name)
            klass = Class.new do
              include Scale::Types::Option
              inner_type inner_type_str
            end
            Scale::Types.const_set name, klass
          else
            Scale::Types.const_get name
          end
        else
          raise "#{type_str} not support inner type: #{type_string}"
        end
      elsif type_string =~ /\[.+;\s*\d+\]/ # array
        scan_result = type_string.scan /\[(.+);\s*(\d+)\]/
        inner_type_name = scan_result[0][0]
        inner_type_len = scan_result[0][1].to_i
        type_name = "#{inner_type_name}Array"

        if !Scale::Types.const_defined?(type_name)
          klass = Class.new do
            include Scale::Types::Array
            inner_type inner_type_name
            length inner_type_len
          end
          Scale::Types.const_set type_name, klass
        else
          Scale::Types.const_get type_name
        end
      elsif type_string.start_with?("(") && type_string.end_with?(")") # tuple
        # TODO: add nested tuple support
        types_with_inner_type = type_string[1...-1].scan(/([A-Za-z]+<[^>]*>)/).first

        types_with_inner_type&.each do |type_str|
          new_type_str = type_str.tr(",", ";")
          type_string = type_string.gsub(type_str, new_type_str)
        end

        type_strs = type_string[1...-1].split(",").map do |type_str|
          type_str.strip.tr(";", ",")
        end

        name = "TupleOf#{type_strs.map(&:camelize2).join("")}"
        name = fix(name)
        if !Scale::Types.const_defined?(name)
          klass = Class.new do
            include Scale::Types::Tuple
            inner_types *type_strs
          end
          Scale::Types.const_set name, klass
        else
          Scale::Types.const_get name
        end
      else
        if type_string == "Enum"
          # TODO: combine values to items
          klass = Class.new do
            include Scale::Types::Enum
            if values.class == ::Hash
              items values
            else
              values(*values)
            end
          end
          name = values.class == ::Hash ? values.values.map(&:camelize2).join("_") : values.map(&:camelize2).join("_")
          name = "Enum_Of_#{rename(name)}_#{klass.object_id}"
          Scale::Types.const_set fix(name), klass
        elsif type_string == "Struct"
          klass = Class.new do
            include Scale::Types::Struct
            items values
          end
          puts "-----"
          # values: {"type_name" => "type_string"}
          inner_type_strings = values.values
          # inner_types = inner_type_strings.map do |inner_type_string|
          #   self.constantize(inner_type_string)
          # end
          name = "Struct_Of_#{inner_type_strings.map {|s| rename(s) }.join}_#{klass.object_id}"
          Scale::Types.const_set fix(name), klass
        elsif type_string == "Set"
          klass = Class.new do
            include Scale::Types::Set
            items values, 1
          end
          name = "Set_Of_#{values.keys.map(&:camelize2).join("_")}_#{klass.object_id}"
          Scale::Types.const_set fix(name), klass
        else
          type_name = (type_string.start_with?("Scale::Types::") ? type_string : "Scale::Types::#{type_string}")
          begin
            type_name.constantize2
          rescue NameError => e
            puts "#{type_string} is not defined"
          end
        end
      end
    end
  end

end

# def fix(name)
#   name
#     .gsub("<", "˂").gsub(">", "˃")
#     .gsub("(", "⁽").gsub(")", "⁾")
#     .gsub(" ", "").gsub(",", "‚")
#     .gsub(":", "։")
# end

def fix(name)
  name
    .gsub("<", "").gsub(">", "")
    .gsub("(", "").gsub(")", "")
    .gsub(" ", "").gsub(",", "")
    .gsub(":", "")
end

def rename(type)
  type = type.gsub("T::", "")
    .gsub("<T>", "")
    .gsub("<T as Trait>::", "")
    .delete("\n")
    .gsub("EventRecord<Event, Hash>", "EventRecord")
    .gsub(/(u)(\d+)/, 'U\2')
  return "Bool" if type == "bool"
  return "Null" if type == "()"
  return "String" if type == "Vec<u8>"
  return "Compact" if type == "Compact<u32>" || type == "Compact<U32>"
  return "Address" if type == "<Lookup as StaticLookup>::Source"
  return "Vec<Address>" if type == "Vec<<Lookup as StaticLookup>::Source>"
  return "Compact" if type == "<Balance as HasCompact>::Type"
  return "Compact" if type == "<BlockNumber as HasCompact>::Type"
  return "Compact" if type =~ /\ACompact<[a-zA-Z0-9\s]*>\z/
  return "CompactMoment" if type == "<Moment as HasCompact>::Type"
  return "CompactMoment" if type == "Compact<Moment>"
  return "InherentOfflineReport" if type == "<InherentOfflineReport as InherentOfflineReport>::Inherent"
  return "AccountData" if type == "AccountData<Balance>"

  if type =~ /\[U\d+; \d+\]/
    byte_length = type.scan(/\[U\d+; (\d+)\]/).first.first.to_i
    return "VecU8Length#{byte_length}"
  end

  type
end

def green(text)
  "\033[32m#{text}\033[0m"
end

def yellow(text)
  "\033[33m#{text}\033[0m"
end

# https://www.ruby-forum.com/t/question-about-hex-signed-int/125510/4
# machine bit length:
#   machine_byte_length = ['foo'].pack('p').size
#   machine_bit_length = machine_byte_length * 8
class Integer
  def to_signed(bit_length)
    unsigned_mid = 2 ** (bit_length - 1)
    unsigned_ceiling = 2 ** bit_length
    (self >= unsigned_mid) ? self - unsigned_ceiling : self
  end

  def to_unsigned(bit_length)
    unsigned_mid = 2 ** (bit_length - 1)
    unsigned_ceiling = 2 ** bit_length 
    if self >= unsigned_mid || self <= -unsigned_mid
      raise "out of scope"
    end
    return unsigned_ceiling + self if self < 0
    self
  end
end

class ::Hash
  # via https://stackoverflow.com/a/25835016/2257038
  def stringify_keys
    h = self.map do |k,v|
      v_str = if v.instance_of? Hash
                v.stringify_keys
              else
                v
              end

      [k.to_s, v_str]
    end
    Hash[h]
  end
end

Scale::Types.debug = false
