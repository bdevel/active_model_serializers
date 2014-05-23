require 'active_model/array_serializer'
require 'active_model/serializable'
require 'active_model/serializer/associations'
require 'active_model/serializer/config'

require 'thread'

module ActiveModel
  class Serializer
    include Serializable

    @mutex = Mutex.new

    class << self
      def inherited(base)
        base._root = _root
        base._attributes = (_attributes || []).dup
        base._flattened_attributes = (_flattened_attributes || {}).dup
        base._associations = (_associations || {}).dup
      end
      
      def setup
        @mutex.synchronize do
          yield CONFIG
        end
      end

      def embed(type, options={})
        CONFIG.embed = type
        CONFIG.embed_in_root = true if options[:embed_in_root] || options[:include]
        ActiveSupport::Deprecation.warn <<-WARN
** Notice: embed is deprecated. **
The use of .embed method on a Serializer will be soon removed, as this should have a global scope and not a class scope.
Please use the global .setup method instead:
ActiveModel::Serializer.setup do |config|
  config.embed = :#{type}
  config.embed_in_root = #{CONFIG.embed_in_root || false}
end
        WARN
      end

      if RUBY_VERSION >= '2.0'
        def serializer_for(resource)
          if resource.respond_to?(:to_ary)
            ArraySerializer
          else
            begin
              Object.const_get "#{resource.class.name}Serializer"
            rescue NameError
              nil
            end
          end
        end
      else
        def serializer_for(resource)
          if resource.respond_to?(:to_ary)
            ArraySerializer
          else
            "#{resource.class.name}Serializer".safe_constantize
          end
        end
      end

      attr_accessor :_root, :_attributes, :_associations, :_flattened_attributes
      alias root  _root=
      alias root= _root=

      def root_name
        name.demodulize.underscore.sub(/_serializer$/, '') if name
      end

      # Returns a hash which indicates which methods will be called
      # on the object to get the value of the attributes. This is
      # useful when you use flattened_attributes or you use
      # different attribute names in your JSON than you do in Ruby
      # and need to know what these mappings are. Note that if 
      # you use any methods in the serializer as an output attribute,
      # only the name of the attribute will be returned and 
      # not a reference to the method.
      def attribute_method_mapping
        @_attributes.inject({}) do |out, attr|
          out[attr] = @_flattened_attributes[attr] || [attr]
          out
        end
      end
      
      def attributes(*attrs)
        @_attributes.concat attrs

        attrs.each do |attr|
          define_method attr do
            object.read_attribute_for_serialization attr
          end unless method_defined?(attr)
        end
      end
      
      def flattened_attributes(*args)
        attrs = args.first
        @_flattened_attributes.merge! attrs
        
        attrs.each_key do |attr_name|
          define_method(attr_name) do
            flatten_calls = attrs[attr_name].dup
            call_to_serialize = flatten_calls.pop
            obj = object # start with the current object
            flatten_calls.each do |call|
              obj = obj.send(call)
              return nil if obj.nil?
            end
            obj.read_attribute_for_serialization(call_to_serialize)
          end unless method_defined?(attr_name)
        end
        attributes *attrs.keys
      end
      
      def has_one(*attrs)
        associate(Association::HasOne, *attrs)
      end

      def has_many(*attrs)
        associate(Association::HasMany, *attrs)
      end

      private

      def associate(klass, *attrs)
        options = attrs.extract_options!

        attrs.each do |attr|
          define_method attr do
            object.send attr
          end unless method_defined?(attr)

          @_associations[attr] = klass.new(attr, options)
        end
      end
    end

    def initialize(object, options={})
      @object        = object
      @scope         = options[:scope]
      @root          = options.fetch(:root, self.class._root)
      @meta_key      = options[:meta_key] || :meta
      @meta          = options[@meta_key]
      @wrap_in_array = options[:_wrap_in_array]
      @only          = Array(options[:only]) if options[:only]
      @except        = Array(options[:except]) if options[:except]
    end
    attr_accessor :object, :scope, :root, :meta_key, :meta

    def json_key
      if root == true || root.nil?
        self.class.root_name
      else
        root
      end
    end
    
    def attributes
      filter(self.class._attributes.dup).each_with_object({}) do |name, hash|
        hash[name] = send(name)
      end
    end

    def associations
      associations = self.class._associations
      included_associations = filter(associations.keys)
      associations.each_with_object({}) do |(name, association), hash|
        if included_associations.include? name
          if association.embed_ids?
            hash[association.key] = serialize_ids association
          elsif association.embed_objects?
            hash[association.embedded_key] = serialize association
          end
        end
      end
    end

    def filter(keys)
      if @only
        keys & @only
      elsif @except
        keys - @except
      else
        keys
      end
    end

    def embedded_in_root_associations
      associations = self.class._associations
      included_associations = filter(associations.keys)
      associations.each_with_object({}) do |(name, association), hash|
        if included_associations.include? name
          if association.embed_in_root?
            association_serializer = build_serializer(association)
            hash.merge! association_serializer.embedded_in_root_associations

            serialized_data = association_serializer.serializable_object
            key = association.root_key
            if hash.has_key?(key)
              hash[key].concat(serialized_data).uniq!
            else
              hash[key] = serialized_data
            end
          end
        end
      end
    end

    def build_serializer(association)
      object = send(association.name)
      association.build_serializer(object, scope: scope)
    end

    def serialize(association)
      build_serializer(association).serializable_object
    end

    def serialize_ids(association)
      associated_data = send(association.name)
      if associated_data.respond_to?(:to_ary)
        associated_data.map { |elem| elem.read_attribute_for_serialization(association.embed_key) }
      else
        associated_data.read_attribute_for_serialization(association.embed_key) if associated_data
      end
    end

    def serializable_object(options={})
      return @wrap_in_array ? [] : nil if @object.nil?
      hash = attributes
      hash.merge! associations
      @wrap_in_array ? [hash] : hash
    end
    alias_method :serializable_hash, :serializable_object
  end
end
