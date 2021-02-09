# frozen_string_literal: true

class EACSerializer < ASpaceExport::Serializer
  serializer_for :eac

  def serialize(eac, _opts = {})
    builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
      _eac(eac, xml)
    end
    builder.to_xml
  end

  private

  # wrapper around nokogiri that creates a node without empty attrs and nodes
  def create_node(xml, node_name, attrs, text)
    return if text.nil? || text.empty?

    xml.send(node_name, clean_attrs(attrs)) do
      xml.text text
    end
  end

  def filled_out?(values, mode = :some)
    if mode == :all
      values.reject { |v| v.to_s.empty? }.count == values.count
    else
      values.reject { |v| v.to_s.empty? }.any?
    end
  end

  def clean_attrs(attrs)
    attrs.reject { |_k, v| v.nil? }
  end

  # Wrapper for working with a list of records:
  # if json['agent_sources']&.any?
  #   xml.sources do
  #     json['agent_sources'].each do |as|
  #       # ...
  # Can be done as: with(xml, json['agent_sources'], :sources) do |src|
  #   # ...
  def with(xml, records, node = nil)
    return unless records&.any?

    records.each do |record|
      if node
        xml.send(node) { yield record }
      else
        yield record
      end
    end
  end

  def _eac(obj, xml)
    json = obj.json
    xml.send('eac-cpf', { 'xmlns' => 'urn:isbn:1-931666-33-4',
                          'xmlns:html' => 'http://www.w3.org/1999/xhtml',
                          'xmlns:xlink' => 'http://www.w3.org/1999/xlink',
                          'xmlns:xsi' => 'http://www.w3.org/2001/XMLSchema-instance',
                          'xsi:schemaLocation' => 'urn:isbn:1-931666-33-4 http://eac.staatsbibliothek-berlin.de/schema/cpf.xsd',
                          'xml:lang' => 'eng' }) do
      _control(json, xml)
      _cpfdesc(json, xml, obj)
    end
  end

  def _control(json, xml)
    xml.control do
      # AGENT_RECORD_IDENTIFIERS
      with(xml, json['agent_record_identifiers']) do |ari|
        if ari['primary_identifier'] == true
          xml.recordId ari['record_identifier']
        else
          attrs = { localType: ari['identifier_type'] }
          create_node(xml, 'otherRecordId', attrs, ari['record_identifier'])
        end
      end

      # AGENT_RECORD_CONTROLS
      if json['agent_record_controls']&.any?
        arc = json['agent_record_controls'].first

        create_node(xml, 'maintenanceStatus', {}, arc['maintenance_status'])
        create_node(xml, 'publicationStatus', {}, arc['publication_status'])

        if filled_out?([arc['maintenance_agency'], arc['agency_name'], arc['maintenance_agency_note']])

          xml.maintenanceAgency do
            if AppConfig[:export_eac_agency_code]
              create_node(xml, 'agencyCode', {}, arc['maintenance_agency'])
            end
            create_node(xml, 'agencyName', {}, arc['agency_name'])
            _descriptive_note(arc['maintenance_agency_note'], xml)
          end
        end

        _language_and_script(
          xml, :languageDeclaration,
          arc['language'],
          arc['script'],
          [arc['language_note']]
        )
      end

      # AGENT_CONVENTIONS_DECLARATIONS
      with(xml, json['agent_conventions_declarations']) do |cd|
        unless filled_out?([cd['name_rule'], cd['citation'], cd['descriptive_note']])
          next
        end

        xml.conventionDeclaration do
          xlink_attrs = {
            'xlink:href' => cd['file_uri'],
            'xlink:actuate' => cd['file_version_xlink_actuate_attribute'],
            'xlink:show' => cd['file_version_xlink_show_attribute'],
            'xlink:title' => cd['xlink_title_attribute'],
            'xlink:role' => cd['xlink_role_attribute'],
            'xlink:arcrole' => cd['xlink_arcrole_attribute'],
            'lastDateTimeVerified' => cd['last_verified_date']
          }

          create_node(xml, 'abbreviation', {}, cd['name_rule'])
          create_node(xml, 'citation', xlink_attrs, cd['citation'])
          _descriptive_note(cd['descriptive_note'], xml)
        end
      end

      # MAINTENANCE_HISTORY
      with(xml, json['agent_maintenance_histories'], :maintenanceHistory) do |mh|
        unless filled_out?([mh['maintenance_event_type'], mh['event_date'], mh['maintenance_agent_type'], mh['agent'], mh['descriptive_note']])
          next
        end

        xml.maintenanceEvent do
          create_node(xml, 'eventType', {}, mh['maintenance_event_type'])

          if filled_out?([mh['event_date']], :all)
            xml.eventDateTime(standardDateTime: mh['event_date'])
          end

          create_node(xml, 'agentType', {}, mh['maintenance_agent_type'])

          create_node(xml, 'agent', {}, mh['agent'])
          create_node(xml, 'eventDescription', {}, mh['descriptive_note'])
        end
      end

      # AGENT_SOURCES
      with(xml, json['agent_sources'], :sources) do |as|
        xlink_attrs = {
          'xlink:href' => as['file_uri'],
          'xlink:actuate' => as['file_version_xlink_actuate_attribute'],
          'xlink:show' => as['file_version_xlink_show_attribute'],
          'xlink:title' => as['xlink_title_attribute'],
          'xlink:role' => as['xlink_role_attribute'],
          'xlink:arcrole' => as['xlink_arcrole_attribute'],
          'lastDateTimeVerified' => as['last_verified_date']
        }

        unless filled_out?([as['source_entry'], as['descriptive_note']])
          next
        end

        xml.source(clean_attrs(xlink_attrs)) do
          create_node(xml, 'sourceEntry', {}, as['source_entry'])
          _descriptive_note(as['descriptive_note'], xml)
        end
      end
    end # of xml.control
  end # of #_control

  def _cpfdesc(json, xml, obj)
    xml.cpfDescription do
      xml.identity do
        # AGENT_IDENTIFIERS
        with(xml, json['agent_identifiers']) do |ad|
          json['agent_identifiers'].each do |ad|
            attrs = { localType: ad['identifier_type'] }

            create_node(xml, 'entityId', attrs, ad['entity_identifier'])
          end
        end

        # ENTITY_TYPE
        entity_type = json['jsonmodel_type'].sub(/^agent_/, '').sub('corporate_entity', 'corporateBody')

        xml.entityType entity_type

        # NAMES
        with(xml, json['names']) do |name|
          # NAMES WITH PARALLEL
          if name['parallel_names']&.any?
            xml.nameEntryParallel do
              _build_name_entry(name, xml, json, obj)

              name['parallel_names'].each do |pname|
                _build_name_entry(pname, xml, json, obj)
              end
            end
          # NAMES NO PARALLEL
          else
            _build_name_entry(name, xml, json, obj)
          end
        end
      end # end of xml.identity

      xml.description do
        # DATES_OF_EXISTENCE
        if json['dates_of_existence']&.any?
          dates = _build_date_collector(json['dates_of_existence'])
          if dates.any?
            xml.existDates do
              dates.each { |d| send(d[:date_method], d[:date], xml) }
            end
          end
        end

        # LANGUAGES USED
        with(xml, json['used_languages'], :languagesUsed) do |lang|
          _language_and_script(
            xml, :languageUsed,
            lang['language'],
            lang['script'],
            lang['notes'].map { |n| n['content'] }
          )
        end

        # PLACES
        with(xml, json['agent_places'], :places) do |place|
          _subject_subrecord(xml, :place, place)
        end

        # OCCUPATIONS
        with(xml, json['agent_occupations'], :occupations) do |occupation|
          _subject_subrecord(xml, :occupation, occupation)
        end

        # FUNCTIONS
        with(xml, json['agent_functions'], :functions) do |function|
          _subject_subrecord(xml, :function, function)
        end

        if json['agent_topics']&.any? ||
           json['agent_genders']&.any?

          xml.localDescriptions do
            # TOPICS
            with(xml, json['agent_topics']) do |topic|
              _subject_subrecord(xml, :localDescription, topic)
            end

            # GENDERS
            with(xml, json['agent_genders']) do |gender|
              next unless filled_out?([gender['gender']])

              xml.localDescription(localType: 'gender') do
                create_node(xml, 'term', {}, gender['gender'])

                gender['dates'].each do |date|
                  if date['date_type_structured'] == 'single'
                    _build_date_single(date, xml)
                  else
                    _build_date_range(date, xml)
                  end
                end

                gender['notes'].each do |n|
                  _descriptive_note(n['content'], xml)
                end
              end
            end
          end # close of xml.localDescriptions
        end # of if

        # NOTES
        # next unless n['publish']
        json['notes']&.each do |n|
          if n['jsonmodel_type'] == 'note_bioghist'
            note_type = :biogHist
          elsif n['jsonmodel_type'] == 'note_general_context'
            note_type = :generalContext
          elsif n['jsonmodel_type'] == 'note_mandate'
            note_type = :mandate
          elsif n['jsonmodel_type'] == 'note_legal_status'
            note_type = :legalStatus
          elsif n['jsonmodel_type'] == 'note_structure_or_genealogy'
            note_type = :structureOrGenealogy
          end

          # next unless n['publish']
          xml.send(note_type) do
            n['subnotes'].each do |sn|
              case sn['jsonmodel_type']
              when 'note_abstract'
                xml.abstract do
                  xml.text sn['content'].join('--')
                end
              when 'note_citation'
                atts = Hash[sn['xlink'].map { |x, v| ["xlink:#{x}", v] }.reject { |a| a[1].nil? }]
                xml.citation(atts) do
                  xml.text sn['content'].join('--')
                end

              when 'note_definedlist'
                xml.list(localType: "defined:#{sn['title']}") do
                  sn['items'].each do |item|
                    xml.item(localType: item['label']) do
                      xml.text item['value']
                    end
                  end
                end
              when 'note_orderedlist'
                xml.list(localType: "ordered:#{sn['title']}") do
                  sn['items'].each do |item|
                    xml.item(localType: sn['enumeration']) do
                      xml.text item
                    end
                  end
                end
              when 'note_chronology'
                atts = sn['title'] ? { localType: sn['title'] } : {}
                xml.chronList(atts) do
                  sn['items'].map { |i| i['events'].map { |e| [i['event_date'], e] } }.flatten(1).each do |pair|
                    date, event = pair
                    atts = date.nil? || date.empty? ? {} : { standardDate: date }
                    xml.chronItem(atts) do
                      xml.event event
                    end
                  end
                end
              when 'note_outline'
                xml.outline do
                  sn['levels'].each do |level|
                    _expand_level(level, xml)
                  end
                end
              when 'note_text'
                xml.p do
                  xml.text sn['content']
                end
              end
            end
          end
        end
      end # end of xml.description

      xml.relations do
        json['agent_resources']&.each do |ar|
          next unless filled_out?([ar['linked_resource']])

          role = if ar['linked_agent_role'] == 'creator'
                   'creatorOf'
                 elsif ar['linked_agent_role'] == 'subject'
                   'subjectOf'
                 else
                   'other'
                 end

          xlink_attrs = {
            'resourceRelationType' => role,
            'xlink:href' => ar['file_uri'],
            'xlink:actuate' => ar['file_version_xlink_actuate_attribute'],
            'xlink:show' => ar['file_version_xlink_show_attribute'],
            'xlink:title' => ar['xlink_title_attribute'],
            'xlink:role' => ar['xlink_role_attribute'],
            'xlink:arcrole' => ar['xlink_arcrole_attribute'],
            'lastDateTimeVerified' => ar['last_verified_date']
          }

          xml.resourceRelation(clean_attrs(xlink_attrs)) do
            create_node(xml, 'relationEntry', {}, ar['linked_resource'])

            if ar['places']&.any?
              xml.places do
                ar['places'].each do |place|
                  subject = place['_resolved']
                  xml.place do
                    xml.placeEntry(vocabularySource: subject['source']) do
                      xml.text subject['terms'].first['term']
                    end
                  end
                end
              end
            end

            ar['dates'].each do |date|
              if date['date_type_structured'] == 'single'
                _build_date_single(date, xml)
              else
                _build_date_range(date, xml)
              end
            end
          end
        end

        json['related_agents']&.each do |ra|
          resolved = ra['_resolved']
          relator = ra['relator']

          name = case resolved['jsonmodel_type']
                 when 'agent_software'
                   resolved['display_name']['software_name']
                 when 'agent_family'
                   resolved['display_name']['family_name']
                 else
                   resolved['display_name']['primary_name']
                 end

          next unless filled_out?([name])

          attrs = { :cpfRelationType => relator, 'xlink:type' => 'simple', 'xlink:href' => AppConfig[:public_proxy_url] + resolved['uri'] }

          xml.cpfRelation(clean_attrs(attrs)) do
            xml.relationEntry name

            if ra['dates']
              if ra['dates']['date_type_structured'] == 'single'
                _build_date_single(ra['dates'], xml)
              else
                _build_date_range(ra['dates'], xml)
              end
            end
          end
        end

        obj.related_records.each do |record|
          role = record[:role] + 'Of'
          record = record[:record]
          atts = { :resourceRelationType => role, 'xlink:type' => 'simple', 'xlink:href' => "#{AppConfig[:public_proxy_url]}#{record['uri']}" }
          xml.resourceRelation(atts) do
            xml.relationEntry record['title']
          end
        end
      end # end of xml.relations

      # ALTERNATIVE SET
      if json['agent_alternate_sets']&.any?
        xml.alternativeSet do
          json['agent_alternate_sets'].each do |aas|
            xlink_attrs = {
              'xlink:href' => aas['file_uri'],
              'xlink:actuate' => aas['file_version_xlink_actuate_attribute'],
              'xlink:show' => aas['file_version_xlink_show_attribute'],
              'xlink:title' => aas['xlink_title_attribute'],
              'xlink:role' => aas['xlink_role_attribute'],
              'xlink:arcrole' => aas['xlink_arcrole_attribute'],
              'lastDateTimeVerified' => aas['last_verified_date']
            }

            unless filled_out?([aas['set_component'], aas['descriptive_note']])
              next
            end

            xml.setComponent(clean_attrs(xlink_attrs)) do
              create_node(xml, 'componentEntry', {}, aas['set_component'])
              _descriptive_note(aas['descriptive_note'], xml)
            end
          end
        end # end of xml.alternativeSet
      end
    end # end of xml.cpfDescription
  end

  def _expand_level(level, xml)
    xml.level do
      level['items'].each do |item|
        if item.is_a?(String)
          xml.item item
        else
          _expand_level(item, xml)
        end
      end
    end
  end

  def _build_date_collector(dates)
    dates.map do |date|
      date_method, expression = _build_date_processor(date)
      # an expression is required
      next unless expression

      { date_method: date_method, date: date }
    end
  end

  def _build_date_processor(date)
    if date['date_type_structured'] == 'single'
      date_method = :_build_date_single
      expression  = date['structured_date_single']['date_expression']
    else
      date_method = :_build_date_range
      expression  = date['structured_date_range']['begin_date_expression'] || date['structured_date_range']['end_date_expression']
    end
    [date_method, expression]
  end

  def _build_date_single(date, xml)
    attrs = { standardDate: date['structured_date_single']['date_standardized'], localType: date['date_label'] }
    create_node(xml, 'date', attrs, date['structured_date_single']['date_expression'])
  end

  def _build_date_range(date, xml)
    xml.dateRange(localType: date['date_label']) do
      begin_attrs = { standardDate: date['structured_date_range']['begin_date_standardized'] }
      end_attrs = { standardDate: date['structured_date_range']['end_date_standardized'] }
      create_node(xml, 'fromDate', begin_attrs, date['structured_date_range']['begin_date_expression'])
      create_node(xml, 'toDate', end_attrs, date['structured_date_range']['end_date_expression'])
    end
  end

  def _build_name_entry(name, xml, _json, obj)
    attrs = { 'xml:lang' => name['language'], 'scriptCode' => name['script'], 'transliteration' => name['transliteration'] }
    xml.nameEntry(clean_attrs(attrs)) do
      obj.name_part_fields.each do |field, localType|
        localType = localType.nil? ? field : localType
        next unless name[field]

        part_attrs = { localType: localType }
        create_node(xml, 'part', part_attrs, name[field])
      end

      dates = _build_date_collector(name['use_dates'])
      if dates.any?
        xml.useDates do
          dates.each { |d| send(d[:date_method], d[:date], xml) }
        end
      end

      if name['authorized']
        xml.authorizedForm name['source'] unless name['source']&.empty?
      else
        xml.alternativeForm name['source'] unless name['source']&.empty?
      end
    end
  end

  def _descriptive_note(note, xml)
    return unless note

    # nokogiri builder special tag for 'p'
    xml.descriptiveNote { create_node(xml, 'p_', {}, note) }
  end

  def _language_and_script(xml, node, language, script, notes = [])
    return unless language || script || notes.any?

    lang_t = I18n.t("enumerations.language_iso639_2.#{language}")
    lang_attrs = { 'languageCode' => language }
    script_t = I18n.t("enumerations.script_iso15924.#{script}")
    script_attrs = { 'scriptCode' => script }
    xml.send(node) do
      create_node(xml, 'language', lang_attrs, lang_t) if language
      create_node(xml, 'script', script_attrs, script_t) if script
      _descriptive_note(notes.compact.join("\n"), xml)
    end
  end

  def _subject_subrecord(xml, node, record)
    record['subjects'].each do |subject|
      subject = subject['_resolved']
      entry_attrs = { vocabularySource: subject['source'] }
      subj_attrs = record['jsonmodel_type'] == 'agent_topic' ? { localType: 'associatedSubject' } : {}
      xml.send(node, subj_attrs) do
        if record['jsonmodel_type'] == 'agent_place'
          create_node(xml, 'placeRole', {}, record['place_role'])
          create_node(xml, 'placeEntry', entry_attrs, subject['terms'].first['term'])
        else
          create_node(xml, 'term', {}, subject['terms'].first['term'])
        end
        _build_date_collector(record['dates']).each do |d|
          send(d[:date_method], d[:date], xml)
          # only the 1st date
          break
        end
        record['notes'].each do |n|
          _descriptive_note(n['content'], xml)
          # only the 1st note
          break
        end
      end
    end
  end
end
