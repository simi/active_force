require 'active_model'
require 'active_attr'
require 'active_attr/dirty'
require 'active_force/active_query'
require 'active_force/association'
require 'yaml'
require 'forwardable'

module ActiveForce
  class SObject
    include ActiveAttr::Model
    include ActiveAttr::Dirty
    include ActiveForce::Association
    STANDARD_TYPES = %w[ Account Contact Opportunity Campaign]

    class_attribute :mappings, :table_name


    class << self
      extend Forwardable
      def_delegators :query, :where, :first, :last, :all, :find, :find_by, :count

      private

      ###
      # Transforms +attribute+ to the conventional Salesforce API name.
      #
      # Example:
      #   > default_api_name :some_attribute
      #   => "Some_Attribute__c"
      def default_api_name(attribute)
        String(attribute).split('_').map(&:capitalize).join('_') << '__c'
      end
    end

    # The table name to used to make queries.
    # It is derived from the class name adding the "__c" when needed.

    def self.table_name
      @table_name ||= custom_table_name || "#{ self.name }__c"
    end

    def self.fields
      mappings.values
    end

    def self.query
      ActiveForce::ActiveQuery.new self
    end

    def self.build sf_table_description
      return unless sf_table_description
      sobject = new
      mappings.each do |attr, sf_field|
        sobject[attr] = sf_table_description[sf_field]
      end
      sobject.changed_attributes.clear
      sobject
    end

    def update_attributes! attributes = {}
      assign_attributes attributes
      return false unless valid?
      sfdc_client.update! table_name, attributes_for_sfdb_update
      changed_attributes.clear
      self
    end

    def update_attributes attributes = {}
      update_attributes! attributes
    rescue Faraday::Error::ClientError => error
      logger 'updating'
    end

    alias_method :update, :update_attributes

    def create!
      return false unless valid?
      self.id = sfdc_client.create! table_name, attributes_for_sfdb_create
      changed_attributes.clear
      self
    end

    def create
      create!
    rescue Faraday::Error::ClientError => error
      logger 'creating'
    end

    def self.create args
      new(args).save
    end

    def save
      if persisted?
        update
      else
        create
      end
    end

    def to_param
      id
    end

    def persisted?
      id?
    end

    def self.field field_name, args = {}
      args[:from] ||= default_api_name(field_name)
      args[:as]   ||= :string
      mappings[field_name] = args[:from]
      attribute field_name, sf_type: args[:as]
    end

    def self.mappings
      @mappings ||= {}
    end

    private

    def looger action
      Rails.logger.info do
        "[SFDC] [#{self.class.model_name}] [#{self.class.table_name}] Error while #{ action }, params: #{hash}, error: #{error.inspect}"
      end
      errors[:base] << error.message
      false
    end

    def attributes_for_sfdb_create
      mappings.map do |attr, sf_field|
        value = read_attribute(attr)
        [sf_field, value] if value
      end.compact.to_h
    end

    def attributes_for_sfdb_update
      changed_mappings.map do |attr, sf_field|
        [sf_field, read_attribute(attr)]
      end.to_h
    end

    def changed_mappings
      mappings.select { |attr, sf_field| changed.include? attr.to_s}
    end

    def self.custom_table_name
      self.name if STANDARD_TYPES.include? self.name
    end

    def read_value field
      case sf_field_type field
      when :multi_picklist
        attribute(field.to_s).reject(&:empty?).join(';')
      else
        attribute(field.to_s)
      end
    end

    def sf_field_type field
      self.class.attributes[field][:sf_tpye]
    end

    def self.picklist field
      picks = sfdc_client.picklist_values(table_name, mappings[field])
      picks.map do |value|
        [value[:label], value[:value]]
      end
    end

    def self.sfdc_client
      @client ||= Restforce.new
    end

    def sfdc_client
      self.class.sfdc_client
    end
  end
end
