require 'yaml'
require 'erb' 
require 'pry'
require 'faraday'
require 'nokogiri'

class Author
  def initialize(hash = {})
    hash.keys.each do |key|
      self.instance_variable_set("@#{key}", hash[key])
      self.class.send(:define_method, key.to_sym) do
          instance_variable_get "@#{key}"
      end
    end
  end
end


class Entry
  def initialize(hash = {})
    hash.keys.each do |key|
      self.instance_variable_set("@#{key}", hash[key])
      self.class.send(:define_method, key.to_sym) do 
          instance_variable_get "@#{key}"
      end
    end
    set_author
    @output_directory = nil
  end
  
  def set_output_directory(dir_name)
    @output_directory = dir_name
  end

  def output_directory
    @output_directory
  end

  def set_page_content(page_html)
    @page_content = page_html
  end

  def page_content
    @page_content
  end

  def set_author
    author_link = self._links["author"][0]["href"]
    @author = Author.new(JSON.parse(Faraday.get(author_link).body))
  end

  def get_binding
    binding
  end
end

class StoredEntry
  attr_reader :slug
  attr_reader :modified_gmt
  attr_accessor :marked

  def initialize(entry_or_hash)
    if entry_or_hash.class == Hash
      @slug = entry_or_hash['slug']
      @modified_gmt = entry_or_hash['modified_gmt']
    else
      @slug = entry_or_hash.slug
      @modified_gmt = entry_or_hash.modified_gmt
    end
    @marked = false
  end

end

class Jagular

  
  def initialize
    #pull in config.yaml
    config_file = File.open("./config.yaml", "r")
    config_data = config_file.read
    @config = YAML.load(config_data)
    config_file.close
    @config["template_path"].length > 0 ? @config["template_path_set"] = true : @config["template_path_set"] = false
    `mkdir #{@config["output_path"]}` if !Dir.exists?(@config["output_path"])
    @last_updated = get_last_updated
    fetch_and_load_helpers
    @pages_json = get_pages_json_from_api
    @stored_pages_json_hash = get_stored_pages_json_hash
    load_yaml_files
  end

  def get_pages_json_from_api
     return Faraday.get(@config['json_api'] + 'wp-json/wp/v2/pages')

  end

  def get_posts_json_from_api
    return Faraday.get(@config['json_api'] + 'wp-json/wp/v2/posts')
  end

  def get_posts
    return JSON.parse(get_posts_from_api)
  end

  def get_stored_pages_json_hash
    if File.exists?(@config["stored_entries_path"] + "pages_json_hash.txt")
      hash_file = File.open(@config["stored_entries_path"] + "pages_json_hash.txt", "r")
      return File.readline(hash_file).chomp!
    else
      return nil
    end
  end

  def hash_contents(contents)
    Digest::MD5.hexdigest(contents)
  end

  def load_yaml_files
    `mkdir #{@config["stored_entries_path"]}` if !Dir.exists?(@config["stored_entries_path"])
    
    `touch #{@config["stored_entries_path"]+"posts.yaml"}` if !File.exists?(@config["stored_entries_path"]+"posts.yaml")
    
    `touch #{@config["stored_entries_path"]+"pages.yaml"}` if !File.exists?(@config["stored_entries_path"]+"pages.yaml")
    posts_file = File.open( @config["stored_entries_path"] + "posts.yaml", "r")
    @stored_posts = YAML.load(File.read(posts_file), permitted_classes: [StoredEntry])
    posts_file.close

    pages_file = File.open( @config["stored_entries_path"] + "pages.yaml", "r")
    @stored_pages = YAML.load(File.read(pages_file), permitted_classes: [StoredEntry])
    pages_file.close

  end


  def dump_yaml_files
    post_entries_to_store = []
    @posts_hash_array.each do |p|
      post_entries_to_store << StoredEntry.new(p)
    end

    posts_file = File.open( @config["stored_entries_path"] + "posts.yaml", "w")
    File.write(posts_file, post_entries_to_store.to_yaml)
    posts_file.close
  end

  def fetch_and_load_helpers
    @config["pages"].keys.each do |k|
      helper_file = get_helper_file(k)
      module_name = get_helper_module_name(k)
      if (helper_file != nil) && (module_name != nil)
        require_relative @config["helper_path"] + helper_file
        #new way: helpers are stand alone modules
        #we pass a reference to our jagular object
        curr_mod = Module.const_get(module_name)
        curr_mod.class.send(:define_method, :jagular_obj) do
          self
        end
        #Helpers should respond to ::run_helper
        
        #in future, to expand Jagular's functionality, check for @config["extensions"] and load and include module extensions
        #old way: helpers as modules to be included
        #self.class.class_eval do
        #  include Module.const_get(module_name)
        #end
      end
    end 
  end

  def get_helper_file(page_key)
    if (@config["pages"][page_key].has_key?("helper") && @config["pages"][page_key]["helper"].has_key?("file"))
      return @config["pages"][page_key]["helper"]["file"]
    else
      return nil
    end
  end

  def get_helper_module_name(page_key)
    if (@config["pages"][page_key].has_key?("helper") && @config["pages"][page_key]["helper"].has_key?("module_name"))
      return @config["pages"][page_key]["helper"]["module_name"]
    else
      return nil
    end
  end

  def get_last_updated
    if File.exists?(@config["timestamp_last_updated"])
      file = File.open(@config["timestamp_last_updated"], "r")
      last_updated = file.readline.chomp!.to_i 
      file.close
    else
      last_updated = @config["starting_time"]
    end
    return last_updated
  end
 

  def pull_template(template)
    if @config["template_path_set"]
     my_template_path = @config["template_path"] + @config[template]["in"]
    else
     my_template_path = "./" + @config[template]["in"]
    end
    template_file = File.open(my_template_path, "r")
    file_erb = template_file.read
    template_file.close
    return file_erb
  end

  def outfile_name(entry, template)
    if match = /\$(.*)\$/.match(template["out"])
      return template["out"].gsub(match[0], entry.send(match[1].to_sym))
    else
      return template["out"]
    end
  end

  def layout_page(entry, template = "layout_default")
    layout_erb = pull_template(template)
    layout_rhtml = ERB.new(layout_erb)
    layout_rhtml.result(entry.get_binding)
  end

  def print_page(entry, template_name)
    template_erb = pull_template(template_name)
    page_html = ERB.new(template_erb)
    entry.set_page_content page_html.result(entry.get_binding)
    output_html = copy_and_replace_images(layout_page(entry))
    output_file_path = @config["output_path"] + output_directory(entry.output_directory) + outfile_name(entry, @config[template_name])
    out_file = File.open(output_file_path, "w")
    File.write(out_file, output_html)
    out_file.close

  end

  def create_new_image_path(old_image_path)
    #split based on match up including to wp-content/uploads
    my_match = /^http.*wp-content\/uploads\/(\d*\/\d*\/)(.*)/.match(old_image_path)
    filename = my_match[2]
    month_day = my_match[1]
    fetch_url = @config["json_api"] + "wp-content/uploads/" + month_day + filename
    `mkdir #{@config["output_path"] + @config["images_directory"]}` if !Dir.exists?(@config["output_path"] + @config["images_directory"])
    write_path = @config["output_path"] + @config["images_directory"] + filename
    resp = Faraday.get(fetch_url)
    File.open(write_path, 'wb') { |wp| wp.write(resp.body) } 
    return @config["images_directory"] + filename
  end

  def copy_and_replace_images(page_html)
  # since the #to_html method dumps an entire html doc, need to run this method after layout+page have been generated
    ndoc = Nokogiri::HTML(page_html)
    images = ndoc.search("img")
    images.each do |i|
       new_image_path = create_new_image_path(i.get_attribute "src")
        i.set_attribute("src", new_image_path)
    end
     ndoc.to_html
  end




  def output_directory(output_dir)
    if output_dir
      `mkdir #{@config["output_path"] + output_dir}` if !Dir.exists(@config["output_path"] + output_dir)
       return output_dir
    else
       return ""
    end
  end

  def wp_timestamp_to_epoch(wp_timestring)
    DateTime.parse(wp_timestring).to_time.to_i
  end

  def get_and_print_posts
    resp = Faraday.get(@config["json_api"] + "wp-json/wp/v2/posts")
    posts = JSON.parse(resp.body)
    posts.each do |p| 
     if wp_timestamp_to_epoch(p["date"]) > @last_updated
        entry = Entry.new(p)
        print_page(entry, "page_default")
        puts "printing #{entry.title['rendered']}"
      end
    end
    run_update
  end

  def run_update


    `echo #{Time.now.to_i.to_s} > #{@config["timestamp_last_updated"]}`
  end


  def update_posts_and_pages
    page_changes = []
    pages_changes << look_for_pages_changed
    delete_yaml_pages_not_marked
    updated_posts = []
    if hash_contents(@posts_json) != @stored_posts_json_hash
      updated_posts = update_posts
    end
      #page_changes << look_for_pages_changed_by_posts(updated_posts)
    #update_pages(page_changes.uniq) if !page_changes.empty?
    #update_posts_and_pages_hashes

  end

  def look_for_pages_changed
    results_arr = []
    if hash_contents(@pages_json) != @stored_pages_json_hash
      @pages.each do |page|
        #if entry_changed_or_new?(jp, @stored_pages)
         #   results_arr << jp["slug"]
        #end
        compare_result = compare_entry(page, @stored_pages)
        if compare_result[:found] == true
          mark_stored_entry(entry, collection)
          results_arr << page["slug"] if compare_result[:changed]
        else
          results_arr << page["slug"]
        end
      end
  
    end
    return results_arr.uniq
  end

  def compare_entry(entry, collection)
      index = collection.find_index {|e| entry["slug"] == e.slug }
      if index == nil
        return {:found => false}
      else
        if wp_timestamp_to_epoch(page["modified_gmt"]) != wp_timestamp_to_epoch(collection[index].modified_gmt)
        return {:found => true, :changed => true}
        else
          return {:found => true, :changed => false}
        end

  end

  def entry_changed_or_new(entry, collection)
    
    if entry.class == Hash
      #check if exists in stored_entries
      index = collection.find_index {|e| entry["slug"] == e.slug }
      if index == nil
        return true
      else
        if wp_timestamp_to_epoch(page["modified_gmt"]) != wp_timestamp_to_epoch(collection[index].modified_gmt) 
        return true
        else
          return false
        end
    else
      raise "only implemented for Hash input"
    end
  end

  def mark_stored_entry(entry, collection)
    stored_index = collection.find_index {|e| entry["slug"] == e.slug}

    collection[stored_index].marked = true
  end

  def delete_yaml_pages_not_marked
    new_list = []
    @stored_pages.each do |se|
      new_list << se if se.marked
    end
    @stored_pages = new_list
  end

  def update_posts
    @posts.each do |post|
      if entry_changed_or_new(post, @stored_posts)

      post_html = render_template_html(post)
      render_with_layout(post, post_html)
    end
    store_posts_yaml
  end




end #end of class

  jrb = Jagular.new
  binding.pry
#  jrb.get_and_print_posts
