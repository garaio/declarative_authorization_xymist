module Authorization
  # The +ObligationScope+ class parses any number of obligations into joins and conditions.
  #
  # In +ObligationScope+ parlance, "association paths" are one-dimensional arrays in which each
  # element represents an attribute or association (or "step"), and "leads" to the next step in the
  # association path.
  #
  # Suppose we have this path defined in the context of model Foo:
  # +{ :bar => { :baz => { :foo => { :attr => is { user } } } } }+
  #
  # To parse this path, +ObligationScope+ evaluates each step in the context of the preceding step.
  # The first step is evaluated in the context of the parent scope, the second step is evaluated in
  # the context of the first, and so forth.  Every time we encounter a step representing an
  # association, we make note of the fact by storing the path (up to that point), assigning it a
  # table alias intended to match the one that will eventually be chosen by ActiveRecord when
  # executing the +find+ method on the scope.
  #
  # +@table_aliases = {
  #   [] => 'foos',
  #   [:bar] => 'bars',
  #   [:bar, :baz] => 'bazzes',
  #   [:bar, :baz, :foo] => 'foos_bazzes' # Alias avoids collisions with 'foos' (already used)
  # }+
  #
  # At the "end" of each path, we expect to find a comparison operation of some kind, generally
  # comparing an attribute of the most recent association with some other value (such as an ID,
  # constant, or array of values).  When we encounter a step representing a comparison, we make
  # note of the fact by storing the path (up to that point) and the comparison operation together.
  # (Note that individual obligations' conditions are kept separate, to allow their conditions to
  # be OR'ed together in the generated scope options.)
  #
  # +@obligation_conditions[<obligation>][[:bar, :baz, :foo]] = [
  #   [ :attr, :is, <user.id> ]
  # ]+
  #
  # After successfully parsing an obligation, all of the stored paths and conditions are converted
  # into scope options (stored in +proxy_options+ as +:joins+ and +:conditions+).  The resulting
  # scope may then be used to find all scoped objects for which at least one of the parsed
  # obligations is fully met.
  #
  # +@proxy_options[:joins] = { :bar => { :baz => :foo } }
  # @proxy_options[:conditions] = [ 'foos_bazzes.attr = :foos_bazzes__id_0', { :foos_bazzes__id_0 => 1 } ]+
  #
  class ObligationScope < ActiveRecord::NamedScope::Scope
    
    # Consumes the given obligation, converting it into scope join and condition options.
    def parse!( obligation )
      @current_obligation = obligation
      obligation_conditions[@current_obligation] ||= {}
      follow_path( obligation )
      
      rebuild_condition_options!
      rebuild_join_options!
    end
    
    protected
    
    # Parses the next step in the association path.  If it's an association, we advance down the
    # path.  Otherwise, it's an attribute, and we need to evaluate it as a comparison operation.
    def follow_path( steps, past_steps = [] )
      if steps.is_a?( Hash )
        steps.each do |step, next_steps|
          path_to_this_point = [past_steps, step].flatten
          reflection = reflection_for( path_to_this_point ) rescue nil
          if reflection
            follow_path( next_steps, path_to_this_point )
          else
            follow_comparison( next_steps, past_steps, step )
          end
        end
      elsif steps.is_a?( Array ) && steps.length == 2
        if reflection = reflection_for( past_steps )
          follow_comparison( steps, past_steps, :id )
        else
          follow_comparison( steps, past_steps[0..-2], past_steps[-1] )
        end
      else
        raise "invalid obligation path #{[past_steps, steps].flatten}"
      end
    end
    
    # At the end of every association path, we expect to see a comparison of some kind; for
    # example, +:attr => [ :is, :value ]+.
    #
    # This method parses the comparison and creates an obligation condition from it.
    def follow_comparison( steps, past_steps, attribute )
      operator = steps[0]
      value = steps[1..-1]
      value = value[0] if value.length == 1

      add_obligation_condition_for( past_steps, [attribute, operator, value] )
    end
    
    # Adds the given expression to the current obligation's indicated path's conditions.
    #
    # Condition expressions must follow the format +[ <attribute>, <operator>, <value> ]+.
    def add_obligation_condition_for( path, expression )
      raise "invalid expression #{expression.inspect}" unless expression.is_a?( Array ) && expression.length == 3
      add_obligation_join_for( path )
      obligation_conditions[@current_obligation] ||= {}
      ( obligation_conditions[@current_obligation][path] ||= Set.new ) << expression
    end
    
    # Adds the given path to the list of obligation joins, if we haven't seen it before.
    def add_obligation_join_for( path )
      map_reflection_for( path ) if reflections[path].nil?
    end
    
    # Returns the model associated with the given path.
    def model_for( path )
      reflection = reflection_for( path )
      reflection.respond_to?( :klass ) ? reflection.klass : reflection
    end
    
    # Returns the reflection corresponding to the given path.
    def reflection_for( path )
      reflections[path] ||= map_reflection_for( path )
    end
    
    # Returns a proper table alias for the given path.  This alias may be used in SQL statements.
    def table_alias_for( path )
      table_aliases[path] ||= map_table_alias_for( path )
    end

    # Attempts to map a reflection for the given path.  Raises if already defined.
    def map_reflection_for( path )
      raise "reflection for #{path.inspect} already exists" unless reflections[path].nil?
      
      reflection = path.empty? ? @proxy_scope : begin
        parent = reflection_for( path[0..-2] )
        parent.klass.reflect_on_association( path.last )
      rescue
        parent.reflect_on_association( path.last )
      end
      raise "invalid path #{path.inspect}" if reflection.nil?
      
      reflections[path] = reflection
      map_table_alias_for( path )  # Claim a table alias for the path.
      
      reflection
    end

    # Attempts to map a table alias for the given path.  Raises if already defined.
    def map_table_alias_for( path )
      return "table alias for #{path.inspect} already exists" unless table_aliases[path].nil?
      
      reflection = reflection_for( path )
      table_alias = reflection.table_name
      if table_aliases.values.include?( table_alias )
        max_length = reflection.active_record.connection.table_alias_length
        table_alias = "#{reflection.name}_#{reflection.active_record.table_name}".to(max_length-1)
      end            
      while table_aliases.values.include?( table_alias )
        table_index = ((table_alias =~ /\w(_\d+?)$/) && $1 || "_1").succ
        table_alias = table_alias[0..-(table_index.length+1)] + table_index
      end
      table_aliases[path] = table_alias
    end

    # Returns a hash mapping obligations to zero or more condition path sets.
    def obligation_conditions
      @obligation_conditions ||= {}
    end

    # Returns a hash mapping paths to reflections.
    def reflections
      @reflections ||= {}
    end
    
    # Returns a hash mapping paths to proper table aliases to use in SQL statements.
    def table_aliases
      @table_aliases ||= {}
    end
    
    # Parses all of the defined obligation conditions and defines the scope's :conditions option.
    def rebuild_condition_options!
      conds = []
      binds = {}
      obligation_conditions.each_with_index do |array, obligation_index|
        obligation, conditions = array
        obligation_conds = []
        conditions.each do |path, expressions|
          model = model_for( path )
          table_alias = table_alias_for(path)
          expressions.each do |expression|
            attribute, operator, value = expression
            attribute_name = model.columns_hash[:"#{attribute}_id"] && :"#{attribute}_id" ||
                             model.columns_hash[attribute.to_s]     && attribute ||
                             :id
            bindvar = "#{table_alias}__#{attribute_name}_#{obligation_index}".to_sym

            attribute_value = value.respond_to?( :descends_from_active_record? ) && value.descends_from_active_record? && value.id ||
                              value.is_a?( Array ) && value[0].respond_to?( :descends_from_active_record? ) && value[0].descends_from_active_record? && value.map( &:id ) ||
                              value
            attribute_operator = case operator
                                 when :contains, :is            : "= :#{bindvar}"
                                 when :does_not_contain, :is_not: "<> :#{bindvar}"
                                 when :is_in                    : "IN (:#{bindvar})"
                                 when :is_not_in                : "NOT IN (:#{bindvar})"
                                 end
            obligation_conds << "#{connection.quote_table_name(table_alias)}.#{connection.quote_table_name(attribute_name)} #{attribute_operator}"
            binds[bindvar] = attribute_value
          end
        end
        obligation_conds << "1=1" if obligation_conds.empty?
        conds << "(#{obligation_conds.join(' AND ')})"
      end
      @proxy_options[:conditions] = [ conds.join( " OR " ), binds ]
    end
    
    # Parses all of the defined obligation joins and defines the scope's :joins option.
    # TODO: Support non-linear association paths.  Right now, we just break down the longest path parsed.
    def rebuild_join_options!
      joins = []
      longest_path = reflections.keys.sort { |a, b| a.length <=> b.length }.last || []
      @proxy_options[:joins] = case longest_path.length
                               when 0: nil
                               when 1: longest_path[0]
                               else
                                 hash = { longest_path[-2] => longest_path[-1] }
                                 longest_path[0..-3].reverse.each do |elem|
                                   hash = { elem => hash }
                                 end
                                 hash
                               end
    end
  end
end