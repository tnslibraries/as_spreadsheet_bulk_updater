class SpreadsheetBulkUpdater

  extend JSONModel

  BATCH_SIZE = 128

  SUBRECORD_DEFAULTS = {
    'dates' => {
      'label' => 'creation',
    },
    'instance' => {
      'jsonmodel_type' => 'instance',
      'sub_container' => {
        'jsonmodel_type' => 'sub_container',
        'top_container' => {'ref' => nil},
      }
    }
  }

  INSTANCE_FIELD_MAPPINGS = [
    ['instance_type', 'instance_type'],
  ]

  SUB_CONTAINER_FIELD_MAPPINGS = [
    ['type_2', 'sub_container_type_2'],
    ['indicator_2', 'sub_container_indicator_2'],
    ['barcode_2', 'sub_container_barcode_2'],
    ['type_3', 'sub_container_type_3'],
    ['indicator_3', 'sub_container_indicator_3']
  ]

  def self.run(filename, job)
    # Run a cursory look over the spreadsheet
    check_sheet(filename)

    # Away!
    errors = []

    updated_uris = []

    column_by_path = extract_columns(filename)

    DB.open(true) do |db|
      resource_id = resource_ids_in_play(filename).fetch(0)

      # before we get too crazy, let's ensure we have all the top containers
      # we need for any instances in the spreadsheet
      top_containers_in_resource = extract_top_containers_for_resource(db, resource_id)
      top_containers_in_sheet = extract_top_containers_from_sheet(filename, column_by_path)

      create_missing_top_containers(top_containers_in_sheet, top_containers_in_resource)


      batch_rows(filename) do |batch|
        to_process = batch.map{|row| [Integer(row.fetch('id')), row]}.to_h

        ao_objs = ArchivalObject.filter(:id => to_process.keys).all
        ao_jsons = ArchivalObject.sequel_to_jsonmodel(ao_objs)

        ao_objs.zip(ao_jsons).each do |ao, ao_json|
          record_changed = false
          row = to_process.fetch(ao.id)
          last_column = nil

          subrecord_updates_by_index = {}
          instance_updates_by_index = {}

          all_text_subnotes_by_type = {}

          begin
            row.values.each do |path, value|
              column = column_by_path.fetch(path)

              last_column = column

              # fields on the AO
              if column.jsonmodel == :archival_object
                next if column.name == :id

                # Validate the lock_version
                if column.name == :lock_version
                  if Integer(value) != ao_json['lock_version']
                    errors << {
                      sheet: SpreadsheetBuilder::SHEET_NAME,
                      column: column.path,
                      row: row.row_number,
                      errors: ["Versions are out sync: #{value} record is now: #{ao_json['lock_version']}"]
                    }
                  end
                else
                  clean_value = column.sanitise_incoming_value(value)

                  if ao_json[path] != clean_value
                    record_changed = true
                    ao_json[path] = clean_value
                  end
                end

              # notes
              elsif column.jsonmodel == :note
                unless all_text_subnotes_by_type.has_key?(column.name)
                  all_text_subnotes = ao_json.notes
                                       .select{|note| note['jsonmodel_type'] == 'note_multipart' && note['type'] == column.name.to_s}
                                       .map{|note| note['subnotes']}
                                       .flatten
                                       .select{|subnote| subnote['jsonmodel_type'] == 'note_text'}

                  all_text_subnotes_by_type[column.name] = all_text_subnotes
                end

                clean_value = column.sanitise_incoming_value(value)

                if (subnote_to_update = all_text_subnotes_by_type[column.name].fetch(column.index, nil))
                  if subnote_to_update['content'] != clean_value
                    record_changed = true

                    # Can only drop a note if apply_deletes? is true
                    if clean_value.to_s.empty? && !apply_deletes?
                      errors << {
                        sheet: SpreadsheetBuilder::SHEET_NAME,
                        column: column.path,
                        row: row.row_number,
                        errors: ["Deleting a note is disabled. Use AppConfig[:spreadsheet_bulk_updater_apply_deletes] = true to enable."],
                      }
                    else
                      subnote_to_update['content'] = clean_value
                    end
                  end
                elsif !clean_value.to_s.empty?
                  record_changed = true

                  sub_note = SUBRECORD_DEFAULTS.fetch('note_text', {}).merge({
                    'jsonmodel_type' => 'note_text',
                    'content' => clean_value
                  })

                  ao_json.notes << SUBRECORD_DEFAULTS.fetch(column.jsonmodel.to_s, {}).merge({
                    'jsonmodel_type' => 'note_multipart',
                    'type' => column.name.to_s,
                    'subnotes' => [sub_note],
                  })

                  all_text_subnotes_by_type[column.name] << sub_note
                end

              # subrecords and instances
              elsif SpreadsheetBuilder::SUBRECORDS_OF_INTEREST.include?(column.jsonmodel)
                subrecord_updates_by_index[column.property_name] ||= {}

                clean_value = column.sanitise_incoming_value(value)

                subrecord_updates_by_index[column.property_name][column.index] ||= {}
                subrecord_updates_by_index[column.property_name][column.index][column.name.to_s] = clean_value

              # instances
              elsif column.jsonmodel == :instance
                instance_updates_by_index[column.index] ||= {}

                clean_value = column.sanitise_incoming_value(value)

                instance_updates_by_index[column.index][column.name.to_s] = clean_value
              end
            end

            # apply subrecords to the json
            #  - update existing
            #  - add new subrecords
            #  - those not updated are deleted
            subrecord_updates_by_index.each do |jsonmodel_property, updates_by_index|
              subrecords_to_apply = []

              updates_by_index.each do |index, subrecord_updates|
                if (existing_subrecord = Array(ao_json[jsonmodel_property.to_s])[index])
                  if subrecord_updates.all?{|_, value| value.to_s.empty? } && apply_deletes?
                    # DELETE!
                    record_changed = true
                    next
                  end

                  if subrecord_updates.any?{|property, value| existing_subrecord[property] != value}
                    record_changed = true
                  end

                  subrecords_to_apply << existing_subrecord.merge(subrecord_updates)
                else
                  if subrecord_updates.values.all?{|v| v.to_s.empty? }
                    # Nothing to do!
                    next
                  end

                  record_changed = true
                  subrecords_to_apply << SUBRECORD_DEFAULTS.fetch(jsonmodel_property.to_s, {}).merge(subrecord_updates)
                end
              end

              ao_json[jsonmodel_property.to_s] = subrecords_to_apply
            end

            # drop any multipart notes with only empty sub notes
            # - drop subnotes empty note_text
            if apply_deletes?
              ao_json.notes.each do |note|
                if note['jsonmodel_type'] == 'note_multipart'
                  note['subnotes'].reject! do |subnote|
                    if subnote['jsonmodel_type'] == 'note_text' && subnote['content'].to_s.empty?
                      record_changed = true
                      true
                    else
                      false
                    end
                  end
                end
              end
              # - drop notes with empty subnotes
              ao_json.notes.reject! do|note|
                if note['jsonmodel_type'] == 'note_multipart' && note['subnotes'].empty?
                  record_changed = true
                  true
                else
                  false
                end
              end
            end

            # handle instance updates
            existing_sub_container_instances = ao_json.instances.select{|instance| instance['instance_type'] != 'digital_object'}
            existing_digital_object_instances = ao_json.instances.select{|instance| instance['instance_type'] == 'digital_object'}
            instances_to_apply = []
            instances_changed = []

            instance_updates_by_index.each do |index, instance_updates|
              if (existing_subrecord = existing_sub_container_instances.fetch(index, false))
                if instance_updates.all?{|_, value| value.to_s.empty? }
                  if apply_deletes?
                    # DELETE!
                    record_changed = true
                    instances_changed = true
                  else
                    errors << {
                      sheet: SpreadsheetBuilder::SHEET_NAME,
                      column: "instances/#{index}",
                      row: row.row_number,
                      errors: ["Deleting an instance is disabled. Use AppConfig[:spreadsheet_bulk_updater_apply_deletes] = true to enable."],
                    }
                  end

                  next
                end

                instance_changed = false

                # instance fields
                INSTANCE_FIELD_MAPPINGS.each do |instance_field, spreadsheet_field|
                  if existing_subrecord[instance_field] != instance_updates[spreadsheet_field]
                    instance_changed = true
                    existing_subrecord[instance_field] = instance_updates[spreadsheet_field]
                  end
                end

                # sub_container fields
                SUB_CONTAINER_FIELD_MAPPINGS.each do |sub_container_field, spreadsheet_field|
                  if existing_subrecord.fetch('sub_container')[sub_container_field] != instance_updates[spreadsheet_field]
                    existing_subrecord.fetch('sub_container')[sub_container_field] = instance_updates[spreadsheet_field]
                    instance_changed = true
                  end
                end

                # the top container
                candidate_top_container = TopContainerCandidate.new(instance_updates['top_container_type'],
                                                                    instance_updates['top_container_indicator'],
                                                                    instance_updates['top_container_barcode'])

                if candidate_top_container.empty?
                  # assume this was intentional and let validation do its thing
                  existing_subrecord['sub_container']['top_container']['ref'] = nil
                else
                  top_container_uri = top_containers_in_resource.fetch(candidate_top_container)

                  if existing_subrecord.fetch('sub_container').fetch('top_container').fetch('ref') != top_container_uri
                    existing_subrecord['sub_container']['top_container']['ref'] = top_container_uri
                    instance_changed = true
                  end
                end

                # did anything change?
                if instance_changed
                  record_changed = true
                  instances_changed = true
                end

                # ready to apply
                instances_to_apply << existing_subrecord
              else
                if instance_updates.values.all?{|v| v.to_s.empty? }
                  # Nothing to do!
                  next
                end

                record_changed = true
                instances_changed = true

                instance_to_create = SUBRECORD_DEFAULTS.fetch('instance').merge(
                  INSTANCE_FIELD_MAPPINGS.map{|target_field, spreadsheet_field| [target_field, instance_updates[spreadsheet_field]]}.to_h
                )

                instance_to_create['sub_container'].merge!(
                  SUB_CONTAINER_FIELD_MAPPINGS.map{|target_field, spreadsheet_field| [target_field, instance_updates[spreadsheet_field]]}.to_h
                )

                candidate_top_container = TopContainerCandidate.new(instance_updates['top_container_type'],
                                                                    instance_updates['top_container_indicator'],
                                                                    instance_updates['top_container_barcode'])

                top_container_uri = top_containers_in_resource.fetch(candidate_top_container)
                instance_to_create['sub_container']['top_container'] = {'ref' => top_container_uri}

                instances_to_apply << instance_to_create
              end
            end

            if instances_changed
              ao_json.instances = instances_to_apply + existing_digital_object_instances
            end


            # Apply changes to the Archival Object!
            if record_changed
              ao_json['position'] = nil
              ao.update_from_json(ao_json)
              job.write_output("Updated archival object #{ao.id} - #{ao_json.display_string}")
              updated_uris << ao_json['uri']
            end

          rescue JSONModel::ValidationException => validation_errors
            validation_errors.errors.each do |json_property, messages|
              errors << {
                sheet: SpreadsheetBuilder::SHEET_NAME,
                json_property: json_property,
                row: row.row_number,
                errors: messages,
              }
            end
          end
        end
      end

      if errors.length > 0
        raise SpreadsheetBulkUpdateFailed.new(errors)
      end
    end

    {
      updated: updated_uris.length,
      updated_uris: updated_uris,
    }
  end

  def self.extract_columns(filename)
    path_row = nil

    XLSXStreamingReader.new(filename).each(SpreadsheetBuilder::SHEET_NAME).each_with_index do |row, idx|
      next if idx == 0
      path_row = row_values(row)
      break
    end

    raise "Missing header row containing paths in #{filename}" if path_row.nil?

    path_row.map do |path|
      column = SpreadsheetBuilder.column_for_path(path)
      raise "Missing column definition for path: #{path}" if column.nil?

      [path, column]
    end.to_h
  end

  def self.extract_ao_ids(filename)
    result = []
    each_row(filename) do |row|
      next if row.empty?
      result << Integer(row.fetch('id'))
    end
    result
  end

  TopContainerCandidate = Struct.new(:top_container_type, :top_container_indicator, :top_container_barcode) do
    def empty?
      top_container_type.nil? && top_container_indicator.nil? && top_container_barcode.nil?
    end

    def to_s
      "#<SpreadsheetBulkUpdater::TopContainerCandidate #{self.to_h.inspect}>"
    end

    def inspect
      to_s
    end
  end

  def self.create_missing_top_containers(in_sheet, in_resource)
    (in_sheet.keys - in_resource.keys).each do |candidate_to_create|
      tc_json = JSONModel(:top_container).new
      tc_json.indicator = candidate_to_create.top_container_indicator
      tc_json.type = candidate_to_create.top_container_type
      tc_json.barcode = candidate_to_create.top_container_barcode

      tc = TopContainer.create_from_json(tc_json)

      in_resource[candidate_to_create] = tc.uri
    end
  end

  def self.extract_top_containers_from_sheet(filename, column_by_path)
    top_containers = {}
    top_container_columns = {}

    column_by_path.each do |path, column|
      if [:top_container_type, :top_container_indicator, :top_container_barcode].include?(column.name)
        top_container_columns[path] = column
      end
    end

    each_row(filename) do |row|
      next if row.empty?
      by_index = {}
      top_container_columns.each do |path, column|
        by_index[column.index] ||= TopContainerCandidate.new
        by_index[column.index][column.name] = row.fetch(path)
      end

      by_index.values.reject(&:empty?).each do |top_container|
        top_containers[top_container] = nil
      end
    end

    top_containers
  end

  def self.extract_top_containers_for_resource(db, resource_id)
    result = {}

    db[:instance]
      .join(:sub_container, Sequel.qualify(:sub_container, :instance_id) => Sequel.qualify(:instance, :id))
      .join(:top_container_link_rlshp, Sequel.qualify(:top_container_link_rlshp, :sub_container_id) => Sequel.qualify(:sub_container, :id))
      .join(:top_container, Sequel.qualify(:top_container, :id) => Sequel.qualify(:top_container_link_rlshp, :top_container_id))
      .join(:archival_object, Sequel.qualify(:archival_object, :id) => Sequel.qualify(:instance, :archival_object_id))
      .filter(Sequel.qualify(:archival_object, :root_record_id) => resource_id)
      .select(Sequel.as(Sequel.qualify(:top_container, :id), :top_container_id),
              Sequel.as(Sequel.qualify(:top_container, :repo_id), :repo_id),
              Sequel.as(Sequel.qualify(:top_container, :type_id), :top_container_type_id),
              Sequel.as(Sequel.qualify(:top_container, :indicator), :top_container_indicator),
              Sequel.as(Sequel.qualify(:top_container, :barcode), :top_container_barcode))
      .each do |row|
        tc = TopContainerCandidate.new
        tc.top_container_type = BackendEnumSource.value_for_id('container_type', row[:top_container_type_id])
        tc.top_container_indicator = row[:top_container_indicator]
        tc.top_container_barcode = row[:top_container_barcode]

        result[tc] = JSONModel(:top_container).uri_for(row[:top_container_id], :repo_id => row[:repo_id])
    end

    result
  end

  def self.resource_ids_in_play(filename)
    ao_ids = extract_ao_ids(filename)

    ArchivalObject
      .filter(:id => ao_ids)
      .select(:root_record_id)
      .distinct(:root_record_id)
      .map{|row| row[:root_record_id]}
  end

  def self.check_sheet(filename)
    errors = []

    # Check AOs exist
    ao_ids = extract_ao_ids(filename)
    existing_ao_ids = ArchivalObject
                        .filter(:id => ao_ids)
                        .select(:id)
                        .map{|row| row[:id]}

    (ao_ids - existing_ao_ids).each do |missing_id|
      errors << {
        sheet: SpreadsheetBuilder::SHEET_NAME,
        row: 'N/A',
        column: 'id',
        errors: ["Archival Object not found for id: #{missing_id}"]
      }
    end

    # Check AOs all from same resource
    resource_ids = resource_ids_in_play(filename)

    if resource_ids.length > 1
      errors << {
        sheet: SpreadsheetBuilder::SHEET_NAME,
        row: 'N/A',
        column: 'id',
        errors: ["Archival Objects must all belong to the same resource."]
      }
    end

    if errors.length > 0
      raise SpreadsheetBulkUpdateFailed.new(errors)
    end
  end

  def self.batch_rows(filename)
    to_enum(:each_row, filename).each_slice(BATCH_SIZE) do |batch|
      yield batch
    end
  end

  def self.each_row(filename)
    headers = nil

    XLSXStreamingReader.new(filename).each(SpreadsheetBuilder::SHEET_NAME).each_with_index do |row, idx|
      if idx == 0
        # header label row is ignored
        next
      elsif idx == 1
        headers = row_values(row)
      else
        yield Row.new(headers.zip(row_values(row)).to_h, idx + 1)
      end
    end
  end

  class SpreadsheetBulkUpdateFailed < StandardError
    attr_reader :errors

    def initialize(errors)
      @errors = errors
    end

    def to_json
      @errors
    end
  end

  Row = Struct.new(:values, :row_number) do
    def fetch(*args)
      self.values.fetch(*args)
    end

    def empty?
      values.all?{|_, v| v.to_s.strip.empty?}
    end
  end

  def self.row_values(row)
    row.map {|s|
      result = s.to_s.strip
      result.empty? ? nil : result
    }
  end

  def self.apply_deletes?
    AppConfig.has_key?(:spreadsheet_bulk_updater_apply_deletes) && AppConfig[:spreadsheet_bulk_updater_apply_deletes] == true
  end

end
