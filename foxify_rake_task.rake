require 'yaml'

def map_id_to_fixture_name(folder)
  id_to_name = Hash.new

  # First gather all mappings between id's and fixture names
  Dir["#{folder}/fixtures/*.yml"].each do |file|
    table_name = File.basename(file, ".yml")

    if data = YAML::load_file(file)
      id_to_name[table_name] = Hash.new

      data.each do |record_name, record|
        if( record['id'] != nil )
          id_to_name[table_name][ record['id'].to_i ] = record_name
        end
      end
    end
  end

  return id_to_name
end

def map_foreign_key_to_reflection(table_names)
  foreign_key_to_table = Hash.new

  Dir.glob("#{Rails.root}/app/models/**/*.rb").each do |f|

    line = File.open(f, &:readline)

    table_name = line.match(/class (.*?) </).try(:[], 1)

    next if table_name.nil?

    class_name = table_name.constantize

    next unless ActiveRecord::Base.descendants.include?(class_name)

    class_name.reflect_on_all_associations(:belongs_to).each do |reflection|
      originating_table = reflection.active_record.table_name
      if(foreign_key_to_table[originating_table].nil?)
        foreign_key_to_table[originating_table] = Hash.new
      end

      foreign_key_to_table[originating_table][reflection.foreign_key] = reflection
    end
  end
  return foreign_key_to_table
end

def load_data(folder)
  data = Hash.new

  # First gather all mappings between id's and fixture names
  Dir["#{folder}/fixtures/*.yml"].each do |file|
    table_name = File.basename(file, ".yml")
    data[table_name] = YAML::load_file(file)
  end

  return data
end

namespace :db do
  namespace :fixtures do
    desc "Replace id-based references with name-based references (Foxy Fixtures)"
    task :foxify => :environment do

      # foxify both traditional and rspec fixtures
      folders = Dir.glob("#{Rails.root}/test") + Dir.glob("#{Rails.root}/spec")
      folders.each do |folder|
        id_to_name = map_id_to_fixture_name(folder)

        table_names = id_to_name.keys

        foreign_key_to_reflection = map_foreign_key_to_reflection(table_names)

        data = load_data(folder)

        # Replace any occurences of:
        #   '<key name>: <record id>'
        #    --- with ---
        #   <table>: <record_name>'
        table_names.each do |table_name|
          data[table_name].each_key do |record_name|
            # get rid of pre-assigned id's, which appear to interfere with
            # foxy fixtures
            data[table_name][record_name].delete('id')

            items = data[table_name][record_name].clone
            items.each_key do |key|
              # look for foreign keys
              if( key =~ /\A(.*_id)\Z/ )
                foreign_key = $1
                reflection = foreign_key_to_reflection[table_name].try(:[], foreign_key)

                # complain if an association seems to be missing
                if( reflection.nil? )
                  puts "Foreign key '#{foreign_key}' for table " +
                    "'#{table_name}' appears to be missing an association in the " +
                    "model."
                else


                  polymorphic = reflection.options[:polymorphic].eql?(true)

                  if polymorphic
                    assoc = reflection.name
                    id = id_to_name[data[table_name][record_name]["#{assoc}_type"]]
                    referenced_id = data[table_name][record_name][key]

                    begin
                      t = data[table_name][record_name]["#{assoc}_type"].to_s.constantize.table_name
                      val = id_to_name[t][referenced_id]
                      val = "#{val} (#{data[table_name][record_name]["#{assoc}_type"]})"

                      data[table_name][record_name][reflection.name.to_s] = val
                      data[table_name][record_name].delete("#{assoc}_id")
                      data[table_name][record_name].delete("#{assoc}_type")
                    rescue => ex
                      puts ex.inspect
                      next
                    end
                  else

                    referenced_table = reflection.klass.table_name

                    referenced_id = data[table_name][record_name][key]
                    if( referenced_id != nil && table_names.include?(referenced_table) )
                      referenced_id = referenced_id.to_i

                      # delete the existing id-based reference
                      data[table_name][record_name].delete(key)

                      # create the new name-based reference
                      data[table_name][record_name][reflection.name.to_s] = id_to_name[referenced_table][referenced_id]
                    end
                  end
                end
              end
            end
          end
        end

        #raise 'here'

        # Move original fixtures to a backup folder
        FileUtils.mkdir_p("#{folder}/fixtures/backup")
        FileUtils.mv( Dir.glob("#{folder}/fixtures/*.yml"),
                      "#{folder}/fixtures/backup")

        # Write out updated fixtures
        table_names.each do |table_name|
          File.open( "#{folder}/fixtures/#{table_name}.yml", 'w' ) do |out|
            #YAML.dump( data[table_name], out )
            out << data[table_name].to_yaml(:SortKeys => true)
          end
        end
      end
    end
  end
end
