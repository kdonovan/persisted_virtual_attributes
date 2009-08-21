# Copyright (c) 2009 Kali Donovan
# 
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

module ActiveRecord #:nodoc
  module With #:nodoc
    # == Overview
    #
    # This PersistedVirtualAttributes plugin persists virtual attributes (hey, that sounds like a good plugin
    # name!) in a specified text column in the database.  Alternatively, you could think of it as making the
    # mechanics of managing serialized data for a model transparent to the user, so rather than:
    #
    #   model.serialized_column = {}
    #   model.serialized_column[:food] => :pickles
    #
    # you can simply do:
    # 
    #   model.food = :pickles
    #
    #
    # == Expectations
    # The plugin requires the existence of a text column on the model it's applied to, unused by anything else
    # in the application (it'll be serialized as a hash and used to store the virtual attributes).
    #
    # Note that only objects which can be serialized by Rails can be persisted.
    #
    # == Motivation / Example uses
    #
    # Consider an application which verifies user identities through various ID verification services.  Each
    # remote service asks its own set of questions (some want Driver's License number and State, others want
    # the user's address, etc.) and returns its own custom information (e.g. yes/no boolean, or a confidence
    # interval, or custom errors).
    #
    # Each verification service is represented by a separate model.  One approach would be to create a new database
    # table for each model, but that's kinda ugly (cluttering the DB unneccessarily) and the models share so
    # much in common that they're already STI subclasses off a general Verification model anyway.
    #
    # Assuming the actual verified/not verified outcome is cached in a boolean column on the User model,
    # the Verification model itself will only rarely be read out of the DB (probably just by admins reviewing 
    # verification history) so adding two serialized text columns isn't a performance concern.  Enter 
    # PersistedVirtualAttributes:
    #
    #   class Verification < ActiveRecord::Base
    #     # ... shared verification stuff here
    #   end
    #
    #   class AddressVerification < Verification
    #     persist_virtual_attributes :in => :custom_data, :attributes => [:street, :city, :state, :zip]
    #
    #     persist_virtual_attributes :in => :response_data, :attributes => [:response_xml, :verification_status]
    # 
    #     validates_presence_of :street, :city, :state
    #   end
    # 
    #   class DriversLicenseVerification < Verification
    #     persist_virtual_attributes :store_column => :custom_data, # Same thing as :in, in case you want to be explicit
    #                               :attributes => [:number, :expiration, :state]
    #
    #     persist_virtual_attributes :in => :response_data,
    #                               :attributes => [:response_json, :verification_status]
    # 
    #     validates_presence_of :state, :number, :expiration
    #     validates_numericality_of :number
    #   end
    # 
    # Now you can do things like:
    # 
    #   >> a = AddressVerification.new(:street => '123 Main St.', :city => 'San Francisco')
    #   >> a.state = 'CA'
    #   >> a.city # => 'San Francisco'
    #   >> a.save # => true
    #   >> b = AddressVerification.first
    #   >> b.street # => '123 Main St.'
    # 
    # Note that you can run validations on the virtual attributes just like you can with real columns.
    # The only difference is that when the model is stored the virtual attributes are serialized to a single
    # text column so each different subclass can easily have its own custom attributes without messing 
    # with the DB schema. Glorious DRYness.
    # 
    module PersistedVirtualAttributes
      
      def self.included(base) #:nodoc
        base.extend ClassMethods
      end
      
      module ClassMethods
        
        # == Configuration options
        #
        # * <tt>store_column</tt> - otherwise-unused text column used to store the virtual attributes when model is saved (aliased to +in+ to allow more semantic invocations)
        # * <tt>attributes</tt> - an array of virtual attributes to create and persist across model reloads from db
        #
        # Example usage:
        #
        #   class Model < ActiveRecord::Base
        #     persist_virtual_attributes :in => 'custom_data', :attributes => [:custom_thing_1, :another_custom_field]
        #   end
        # 
        # == Multiple Invocations
        #
        # You can call persist_virtual_attributes multiple times per model, as long as you give each call a different 
        # +store_column+ and unique attributes.  Attributes will be stored in the appropriate column, obviously, which
        # makes it easy to partition groups of attributes (e.g. setting custom local fields in one column, while 
        # storing custom response fields from a remote service in another).
        #
        # To list persisted attributes, either all or just those stored in a particular column, try some combination of
        # +custom_attributes+, +custom_attribute_stores+, and +custom_attributes_by_store+.
        #
        def persist_virtual_attributes(opts = {})
          store_column = (opts[:store_column] || opts[:in]).try(:to_sym)
          new_custom_attributes = (opts[:attributes] || []).map(&:to_sym)
          
          # General setup
          cattr_accessor :custom_attribute_stores, :custom_attributes, :custom_attributes_by_store
          self.custom_attribute_stores ||= []
          self.custom_attributes ||= []
          self.custom_attributes_by_store ||= {}
          
          # ==================================================
          # = Verify inputs before doing anything meaningful =
          # ==================================================
          
          # Ensure we received the options we need
          raise ArgumentError.new('PersistVirtualAttributes: No store_column provided') unless store_column
          raise ArgumentError.new('PersistVirtualAttributes: No virtual attributes provided') if new_custom_attributes.empty?
          
          # Then ensure the column exists... 
          store_column_as_column = self.columns.detect{|c| c.name == store_column.to_s}
          raise ActiveRecordError.new("PersistVirtualAttributes: No such column: #{store_column}") unless store_column_as_column
          # ... and it's a text column
          raise ActiveRecordError.new("PersistVirtualAttributes: #{store_column} is not a text column") unless store_column_as_column.type == :text

          # Finally, make sure the attributes don't already exist
          existing_columns = self.column_names.map(&:to_sym) & new_custom_attributes
          raise ActiveRecordError.new("PersistVirtualAttributes: Cannot create virtual attributes (columns already exist): #{existing_columns.inspect}") unless existing_columns.empty?
          existing_attributes = self.custom_attributes & new_custom_attributes
          raise ActiveRecordError.new("PersistVirtualAttributes: Cannot create virtual attributes (already defined): #{existing_attributes.inspect}") unless existing_attributes.empty?
          
          
          # ===================
          # = OK, get to work =
          # ===================
          
          serialize store_column, Hash
          self.custom_attribute_stores << store_column
          self.custom_attributes_by_store[store_column] = []
          
          # Now process the provided attributes
          new_custom_attributes.each do |attrib|
            # Store the virtual attribute in the store_column column 
            define_method "#{attrib}=" do |val|
              self.send("#{store_column}=", {}) if self.send(store_column).blank?
              self.send(store_column).send('[]=', attrib, val)
            end
            
            # Grab the virtual attribute out of the store_column column
            define_method attrib do
              self.send("#{store_column}=", {}) if self.send(store_column).blank?
              self.send(store_column).send('[]', attrib)
            end
            
            # Add the attribute to the list of virtual attribs (global and by store)
            self.custom_attributes << attrib
            self.custom_attributes_by_store[store_column] << attrib
          end
          
        end
        
     end
    end
    
  end
end