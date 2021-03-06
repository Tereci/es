require 'pry'
require 'chronic'
require 'jsonify'
require 'json'
require 'rainbow'
require 'yajl'
require 'active_support/time'
require 'active_support/ordered_hash'
require 'terminal-table'

module Es

  class InsufficientSpecificationError < RuntimeError
  end

  class IncorrectSpecificationError < RuntimeError
  end
  
  class UnableToMerge < RuntimeError
  end

  class Timeframe
    INTERVAL_UNITS = [:day, :week, :month, :year]
    DAY_WITHIN_PERIOD = [:first, :last]
    attr_accessor :to, :from, :interval_unit, :interval, :day_within_period

    def self.parse(spec)
      if spec == 'latest' then
        Timeframe.new({
          :to => 'today',
          :from => 'yesterday'
        })
      else
        Timeframe.new(spec)
      end
    end

    def initialize(spec)
      validate_spec(spec)
      @spec = spec
      @to = Chronic.parse(spec[:to])
      @from = spec[:from] ? Chronic.parse(spec[:from]) : to.advance(:days => -1)
      @interval_unit = spec[:interval_unit] || :day
      @interval = spec[:interval] || 1
      @day_within_period = spec[:day_within_period] || :last
    end

    def validate_spec(spec)
      fail IncorrectSpecificationError.new("Timeframe should have a specification") if spec.nil?
      fail InsufficientSpecificationError.new("To key was not specified during the Timeframe creation") unless spec.has_key?(:to)
      fail InsufficientSpecificationError.new("From key was not specified during the Timeframe creation") unless spec.has_key?(:from)
      fail IncorrectSpecificationError.new("Interval key should be a number") if spec[:interval] && !spec[:interval].is_a?(Fixnum)
      fail IncorrectSpecificationError.new("Interval_unit key should be one of :day, :week, :month, :year") if spec[:interval_unit] && !INTERVAL_UNITS.include?(spec[:interval_unit].to_sym)
      fail IncorrectSpecificationError.new("Day within period should be one of #{DAY_WITHIN_PERIOD.join(', ')}") if spec[:day_within_period] && !DAY_WITHIN_PERIOD.include?(spec[:day_within_period].to_sym)
    end

    def to_extract_fragment(pid, options = {})
      {
        :endDate            => to.strftime('%Y-%m-%d'),
        :startDate          => from.strftime('%Y-%m-%d'),
        :intervalUnit       => interval_unit,
        :dayWithinPeriod    => day_within_period.to_s.upcase,
        :interval           => interval
      }
    end

  end

  class Extract

    attr_accessor :entities, :timeframe, :timezone

    def self.parse(spec, a_load)
      global_timeframe = parse_timeframes(spec[:timeframes]) || parse_timeframes("latest")
      timezone = spec[:timezone]
      parsed_entities = spec[:entities].map do |entity_spec|
        entity_name = entity_spec[:entity]
        load_entity = a_load.get_merged_entity_for(entity_name)
        fields = entity_spec[:fields].map do |field|
          if load_entity.has_field?(field)
            load_entity.get_field(field)
          elsif field == "DeletedAt"
            Es::Field.new("DeletedAt", "time")
          elsif field == "IsDeleted"
            Es::Field.new("IsDeleted", "attribute")
          elsif field == "snapshot"
            Es::SnapshotField.new("snapshot", "snapshot")
          elsif field == "autoincrement"
            Es::AutoincrementField.new("generate", "autoincrement")
          elsif field == "duration"
            Es::DurationField.new("duration", "duration")
          elsif field == "velocity"
            Es::DurationField.new("velocity", "velocity")
          elsif field.respond_to?(:keys) && field.keys.first == :hid
            Es::HIDField.new('hid', "historicid", {
              :entity => field[:hid][:from_entity],
              :fields => field[:hid][:from_fields],
              :through => field[:hid][:connected_through]
            })
          else
            fail InsufficientSpecificationError.new("The field #{field.to_s.bright} was not found in either the loading specification nor was recognized as a special column")
          end
        end
        parsed_timeframe = parse_timeframes(entity_spec[:timeframes])
        Entity.new(entity_name, {
          :fields => fields,
          :file   => entity_spec[:file],
          :timeframe => parsed_timeframe || global_timeframe || (fail "Timeframe has to be defined"),
          :timezone => timezone
        })
      end

      Extract.new(parsed_entities)
    end

    def self.parse_timeframes(timeframe_spec)
      return nil if timeframe_spec.nil?
      return Timeframe.parse("latest") if timeframe_spec == "latest"
      if timeframe_spec.is_a?(Array) then
        timeframe_spec.map {|t_spec| Es::Timeframe.parse(t_spec)}
      else
        Es::Timeframe.parse(timeframe_spec)
      end
    end

    def initialize(entities, options = {})
      @entities = entities
      @timeframe = options[:timeframe]
      @timezone = options[:timezone] || 'UTC'
    end

    def get_entity(name)
      entities.detect {|e| e.name == name}
    end

    def to_extract_fragment(pid, options = {})
      entities.map do |entity|
        entity.to_extract_fragment(pid, options)
      end
    end

  end

  class Load
    attr_accessor :entities

    def self.parse(spec)
      Load.new(spec.map do |entity_spec|
        Entity.parse(entity_spec)
      end)
    end

    def initialize(entities)
      @entities = entities
      validate
    end

    def get_merged_entity_for(name)
      entities_to_merge = entities.find_all {|e| e.name == name}
      fail UnableToMerge.new("There is no entity #{name.bright} in current load object.") if entities_to_merge.empty?
      merged_fields = entities_to_merge.inject([]) {|all, e| all.concat e.fields}
      Entity.new(name, {
        :file => "MERGED",
        :fields => merged_fields
      })
    end

    def get_entity(name)
      entities.detect {|e| e.name == name}
    end

    def validate
      names = entities.map {|e| e.name}.uniq
      names.each do |name|
        merged_entity = get_merged_entity_for(name)
      end
    end

    def to_config
      entities.map {|e| e.to_load_config}
    end

    def to_config_file(filename)
      File.open(filename, 'w') do |f|
        f.write(JSON.pretty_generate(to_config))
      end
    end

  end

  class Entity
    attr_accessor :name, :fields, :file, :timeframes, :timezone

    def self.parse(spec)
      entity = Entity.new(spec[:entity], {
        :file => spec[:file],
        :fields => spec[:fields] && spec[:fields].map {|field_spec| Field.parse(field_spec)}
      })
    end

    def initialize(name, options)
      fail Es::IncorrectSpecificationError.new("Entity name is not specified.") if name.nil?
      fail Es::IncorrectSpecificationError.new("Entity name should be a string.") unless name.is_a?(String)
      fail Es::IncorrectSpecificationError.new("Entity name should not be empty.") if name.strip.empty?
      fail Es::IncorrectSpecificationError.new("File is not specified.") if options[:file].nil?
      fail Es::IncorrectSpecificationError.new("File should be a string.") unless options[:file].is_a?(String)
      fail Es::IncorrectSpecificationError.new("Fields are not specified.") if options[:fields].nil?
      fail Es::IncorrectSpecificationError.new("Entity should contain at least one field.") if options[:fields].empty?
      # fail Es::IncorrectSpecificationError.new("Entity should contain at least one recordid field.") if !options[:fields].any? {|f| f.is_recordid?}

      @name = name
      @fields = options[:fields]
      @file = options[:file]
      if options[:timeframe] && !options[:timeframe].is_a?(Array)
        @timeframes = [options[:timeframe]]
      else
        @timeframes = options[:timeframe]
      end
      @timezone = options[:timezone] || 'UTC'
      fail Es::IncorrectSpecificationError.new("Entity #{name} should not contain multiple fields with the same name.") if has_multiple_same_fields?
    end

    def has_multiple_same_fields?
      fields_without = fields.find_all {|f| !f.is_recordid? && f.type != Field::TIMESTAMP_TYPE}
      fields_without.uniq_by {|s| s.name}.count != fields_without.count
    end

    def to_extract_fragment(pid, options = {})
      populates_element = (fields.find {|f| f.is_hid?} || fields.find {|f| f.is_recordid?} || fields.find {|f| f.is_autoincrement?})
      fail "Needs to have at least on ID element. Use Id, HID, autoincrement" if populates_element.nil?
      pretty = options[:pretty].nil? ? true : options[:pretty]
      read_map = [{
        :file       => Es::Helpers.web_dav_extract_destination_dir(pid, self) + '/' + Es::Helpers.destination_file(self),
        :populates  => populates_element.name,
        :columns    => (fields.map do |field|
          field.to_extract_fragment(pid, options)
        end)
      }]


      d = ActiveSupport::OrderedHash.new
      d['entity'] = name
      d['timezone'] = timezone
      d['readMap'] = (pretty ? read_map : read_map.to_json)
      d['computedStreams'] = '[{"type":"computed","ops":[]}]'
      d['timeFrames'] = (timeframes.map{|t| t.to_extract_fragment(pid, options)})

      task = ActiveSupport::OrderedHash.new
      task['readTask'] = d
      task

    end

    def to_load_fragment(pid)
      {
        :uploadTask => {
          :entity       => name,
          :file         => Es::Helpers.web_dav_load_destination_dir(pid, self) + '/' + Es::Helpers.destination_file(self),
          :attributes   => fields.map {|f| f.to_load_fragment(pid)}
        }
      }
    end

    def to_load_config
      {
        :entity => name,
        :file   => file,
        :fields => fields.map {|f| f.to_load_config}
      }
    end

    def to_extract_config
      {
        :timezone => timezone,
        :entities => [{
          :entity   => name,
          :file     => file,
          :fields   => fields.map {|f| f.name}
        }]
      }
    end

    def to_table
      t = Terminal::Table.new :headings => [name]
      fields.map {|f| t << [f.name]}
      t
    end

    def has_field?(name)
      !!fields.detect {|f| f.name == name}
    end

    def get_field(name)
      fields.detect {|f| f.name == name}
    end

    def add_field(field)
      fail Es::IncorrectSpecificationError.new("There already is a field with name #{field.name} in entity #{name}") if fields.detect {|f| f.name == field.name}
      fields << field
    end

    def load(pid)
      begin
        GoodData.connection.upload file, Es::Helpers.load_destination_dir(pid, self)
        data = GoodData.post "/gdc/projects/#{pid}/eventStore/stores/#{ES_NAME}/uploadTasks", to_load_fragment(pid).to_json
        link = data["asyncTask"]["link"]["poll"]
        response = GoodData.get(link, :process => false)
        while response.code != 204
          sleep 10
          response = GoodData.get(link, :process => false)
        end
      rescue RestClient::RequestFailed => error
        parser = Yajl::Parser.new(:symbolize_keys => true)
        doc = parser.parse(error.response)
        pp doc
        exit 1
      end
    end
  end

# Fields

  class Field

    ATTRIBUTE_TYPE      = "attribute"
    RECORDID_TYPE       = "recordid"
    DATE_TYPE           = "date"
    TIME_TYPE           = "time"
    FACT_TYPE           = "fact"
    TIMESTAMP_TYPE      = "timestamp"
    AUTOINCREMENT_TYPE  = "autoincrement"
    SNAPSHOT_TYPE       = "snapshot"
    HID_TYPE            = "hid"
    HISTORIC_TYPE       = "historicid"
    DURATION_TYPE       = "duration"
    VELOCITY_TYPE       = "velocity"
    IS_DELETED_TYPE     = "isDeleted"

    FIELD_TYPES = [ATTRIBUTE_TYPE, RECORDID_TYPE, DATE_TYPE, TIME_TYPE, FACT_TYPE, TIMESTAMP_TYPE, AUTOINCREMENT_TYPE, SNAPSHOT_TYPE, HID_TYPE, HISTORIC_TYPE, DURATION_TYPE, VELOCITY_TYPE, IS_DELETED_TYPE]

    def self.parse(spec)
      fail InsufficientSpecificationError.new("Field specification is empty") if spec.nil?
      fail InsufficientSpecificationError.new("Field specification is should be an object") unless spec.is_a?(Hash)
      Field.new(spec[:name], spec[:type])
    end

    attr_accessor :type, :name

    def is_recordid?
      type == RECORDID_TYPE
    end

    def is_snapshot?
      false
    end

    def is_duration?
      false
    end

    def is_autoincrement?
      false
    end

    def is_hid?
      false
    end

    def is_velocity?
      false
    end

    def initialize(name, type)
      fail Es::IncorrectSpecificationError.new("The field name \"#{name.bright}\" does not have type specified. Type should be one of [#{FIELD_TYPES.join(', ')}]") if type.nil?
      fail Es::IncorrectSpecificationError.new("The type of field name \"#{name.bright}\" should be a string.") unless type.is_a?(String)
      fail Es::IncorrectSpecificationError.new("The field name \"#{name.bright}\" does have wrong type specified. Specified \"#{type.bright}\" should be one of [#{FIELD_TYPES.join(', ')}]") unless FIELD_TYPES.include?(type) || type == "none"
      @name = name
      @type = type
    end

    def to_extract_fragment(pid, options = {})
      {
        :name => name,
        :preferred => name,
        :definition => {
          :ops => [{
            :type => Es::Helpers.type_to_type(type),
            :data => name
          }],
          :type => Es::Helpers.type_to_operation(type)
        }
      }
    end

    def to_load_fragment(pid)
      {
        :name => name,
        :type => Es::Helpers.type_to_load_type(type)
      }
    end

    def to_load_config
      {
        :name => name,
        :type => (type == 'none' ? '' : type)
      }
    end

    def ==(other)
      other.name == name
    end

  end

  class SnapshotField < Field

    attr_accessor :type, :name

    def is_snapshot?
      true
    end

    def to_extract_fragment(pid, options = {})
      {
        :name => name,
        :preferred => name,
        :definition => {
          :type => "snapshot",
          :data => "date"
        }
      }
    end

  end

  class HIDField < Field

    attr_accessor :type, :name, :entity, :fields, :through

    def is_hid?
      true
    end

    def initialize(name, type, options)
      name = "#{name}-#{options[:entity]}"
      super(name, type)
      @entity = options[:entity] || fail("Entity has to be scpecified for a HID Field")
      @fields = options[:fields] || fail("Fields has to be scpecified for a HID Field")
      @through = options[:through]
    end

    def to_extract_fragment(pid, options = {})
      {
        :name => name,
        :preferred => name,
        :definition => {
          :ops  => [
            through.nil? ? {:type => RECORDID_TYPE} : {:type => "stream", :data => through},
            {
              :type => "entity",
              :data => entity,
              :ops  => fields.map do |f|
                {
                  :type => "stream",
                  :data => f
                }
              end
            }
          ],
          :type => "historicid"
        }
      }
    end

  end

  class DurationField < Field

    attr_accessor :type, :name

    def is_duration?
      true
    end

    def to_extract_fragment(pid, options = {})
      {
          :name       => "StageDuration",
          :preferred  => "stageduration",
          :definition => {
              :type => "case",
              :ops  => [{
                  :type => "option",
                  :ops => [{
                      :type => "=",
                      :ops => [{
                          :type => "stream",
                          :data => "IsClosed"
                      },
                      {
                          :type => "match",
                          :data => "false"
                      }]
                  },
                  {
                      :type => "duration",
                      :ops  => [{
                          :type => "stream",
                          :data => "StageName"
                      }]
                  }]
              },
              {
                  :type => "option",
                  :ops  => [{
                      :type => "const",
                      :data => 1
                  },
                  {
                      :type => "const",
                      :data => 0
                  }]
              }]
          }
      }
    end
  end

  class VelocityField < Field

    attr_accessor :type, :name

    def is_velocity?
      true
    end

    def to_extract_fragment(pid, options = {})
      {
        :name => "StageVelocity",
        :preferred => "stagevelocity",
        :definition => {
            :type => "velocity",
            :ops => [{
                :type => "stream",
                :data => "StageName"
            }]
        }
      }
    end
  end


  class AutoincrementField < Field

    attr_accessor :type, :name

    def is_autoincrement?
      true
    end

    def to_extract_fragment(pid, options = {})
      {
        :name => name,
        :preferred => name,
        :definition => {
          :type => "generate",
          :data => "autoincrement"
        }
      }
    end
  end

  module Helpers
    TEMPLATE_DIR = "./lib/templates"

    def self.has_more_lines?(path)
      counter = 0
      File.open(path, "r") do |infile|
        while (line = infile.gets)
          counter += 1
          break if counter > 2
        end
      end
      counter > 1
    end

    def self.load_config(filename, validate=true)
        json = File.new(filename, 'r')
          parser = Yajl::Parser.new(:symbolize_keys => true)
        begin
          doc = parser.parse(json)
        rescue Yajl::ParseError => e
          fail Yajl::ParseError.new("Failed during parsing file #{filename}\n" + e.message)
        end
    end

    def self.web_dav_load_destination_dir(pid, entity)
      "/uploads/#{pid}"
    end

    def self.web_dav_extract_destination_dir(pid, entity)
      "/out_#{pid}_#{entity.name}"
    end

    def self.load_destination_dir(pid, entity)
      "#{pid}"
    end

    def self.extract_destination_dir(pid, entity)
      "out_#{pid}_#{entity.name}"
    end

    def self.destination_file(entity, options={})
      with_date = options[:with_date]
      deleted = options[:deleted]
      source = entity.file
      filename = File.basename(source)
      base =  File.basename(source, '.*')
      ext = File.extname(filename)
      base = deleted ? "#{base}_deleted" : base
      with_date ? base + '_' + DateTime.now.strftime("%Y-%M-%d_%H:%M:%S") + ext : base + ext
    end

    def self.type_to_load_type(type)
      types = {
        Es::Field::RECORDID_TYPE        => "recordid",
        Es::Field::TIMESTAMP_TYPE       => "timestamp",
        Es::Field::ATTRIBUTE_TYPE       => "attribute",
        Es::Field::FACT_TYPE            => "fact",
        Es::Field::TIME_TYPE            => "timeAttribute",
        Es::Field::DATE_TYPE            => "timeAttribute",
        Es::Field::IS_DELETED_TYPE      => 'isDeleted'
      }
      if types.has_key?(type) then
        types[type]
      else
        fail "Type #{type} not found."
      end
    end


    def self.type_to_type(type)
      types = {
        Es::Field::RECORDID_TYPE        => "recordid",
        Es::Field::ATTRIBUTE_TYPE       => "stream",
        Es::Field::FACT_TYPE            => "stream",
        Es::Field::SNAPSHOT_TYPE        => "snapshot",
        Es::Field::TIME_TYPE            => "stream",
        Es::Field::DATE_TYPE            => "stream"
        
      }
      if types.has_key?(type) then
        types[type]
      else
        fail "Type #{type} not found."
      end
    end

    def self.type_to_operation(type)
      types = {
        Es::Field::RECORDID_TYPE      => "value",
        Es::Field::ATTRIBUTE_TYPE     => "value",
        Es::Field::FACT_TYPE          => "number",
        Es::Field::SNAPSHOT_TYPE      => "snapshot",
        Es::Field::TIME_TYPE          => "key",
        Es::Field::DATE_TYPE          => "date"
      }
      if types.has_key?(type) then
        types[type]
      else
        fail "Type #{type} not found."
      end
    end
  end

end

# Hack for 1.8.7
# uniq on array does not take block
module Enumerable
  def uniq_by
    seen = Hash.new { |h,k| h[k] = true; false }
    reject { |v| seen[yield(v)] }
  end
end