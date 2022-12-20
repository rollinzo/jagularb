require 'yaml'
require 'erb'
require 'pry'
require 'faraday'
require 'nokogiri'


class Jagular

  def initialize
     #pull in config.yaml
    config_file = File.open("./config.yaml", "r")
    config_data = config_file.read
    @config = YAML.load(config_data)
    config_file.close
    @config["template_path"].length > 0 ? @config["template_path_set"] = true : @config["template_path_set"] = false
    #`mkdir #{@config["output_path"]}` if !Dir.exists?(@config["output_path"])
    #@last_updated = get_last_updated
    @globals = {}
    @globals["site_url"] = @config["site_url"]
    @globals["assets_url"] = @config["site_url"] + "assets/"
    @globals["css_url"] = @config["site_url"] + "css/"
    @pages = get_pages
    #add page config to pages
    @pages.each do |page|
      page["globals"] = @globals
      if @config["pages"].include? page["slug"]
        template_name = @config["pages"][page["slug"]]
        page["template"] = @config["templates"][template_name]
      else
        page["template"] = @config["templates"]["page_default"]
      end

    end
    fetch_and_load_helpers
    load_matchers
    @posts = get_posts
    @posts.each do |post|
      post["globals"] = @globals
      post["template"] = @config["templates"]["post_default"]
      post["ruby_datetime"] = DateTime.parse(post["modified_gmt"]).to_time
    end
    @users = get_users
    @media = get_media
    @tags = get_tags
  end

  #PULL JSON FROM WORDPRESS

  def get_pages_json_from_api
    return Faraday.get(@config['json_api'] + 'wp-json/wp/v2/pages').body

  end

  def get_posts_json_from_api
    return Faraday.get(@config['json_api'] + 'wp-json/wp/v2/posts').body
  end

  def get_users_json_from_api
    return Faraday.get(@config['json_api'] + 'wp-json/wp/v2/users').body
  end


  def get_media_json_from_api
    return Faraday.get(@config['json_api'] + 'wp-json/wp/v2/media').body
  end


  def get_tags_json_from_api
    return Faraday.get(@config['json_api'] + 'wp-json/wp/v2/tags').body
  end

  def get_pages
    return @pages || JSON.parse(get_pages_json_from_api)
  end

  def get_posts
    return @posts || JSON.parse(get_posts_json_from_api)
  end

  def get_users
     return @users || JSON.parse(get_users_json_from_api)
  end


  def get_media
     return @media || JSON.parse(get_media_json_from_api)
  end


  def get_tags
     return @tags || JSON.parse(get_tags_json_from_api)
  end
  #LOAD HELPERS

  def fetch_and_load_helpers
    @pages.each do |page|
      if page["template"]["helper"] != nil
        helper_file = get_helper_file(page)
        helper_name = get_helper_module_name(page)
        if (helper_file != nil) && (helper_name != nil)
          require_relative @config["helper_path"] + helper_file
          curr_mod = Module.const_get(helper_name)
          mod_obj = curr_mod.send(:new, self)
          page["template"]["helper"]["obj"] = mod_obj
          #page["template"]["helper"]["function"] = mod_obj.get_helper_function
        end
      else

        #assign default helper
        page["template"]["helper"] ={}
        obj = Object.new
        page["template"]["helper"]["obj"] = obj
        obj.define_singleton_method(:run_helpers) do |entry|
            {}
        end

      end
    end
    [ @config["templates"]["post_default"], @config["templates"]["page_default"]].each do |template|
          require_relative @config["helper_path"] + template["helper"]["file"]
          curr_mod = Module.const_get(template["helper"]["module_name"])
          mod_obj = curr_mod.send(:new, self)
          template["helper"]["obj"] = mod_obj

    end

  end

  def get_helper_file(page)
    if (page.has_key?("template")) && (page["template"].has_key?("helper") && page["template"]["helper"].has_key?("file"))
      return page["template"]["helper"]["file"]
    else
      return nil
    end
  end

  def get_helper_module_name(page)
    if (page.has_key?("template")) && (page["template"].has_key?("helper") && page["template"]["helper"].has_key?("module_name"))
      return page["template"]["helper"]["module_name"]
    else
      return nil
    end
  end

  #LOAD MATCHERS

  def load_matchers
    @matchers = []
    @config["matchers"].keys.each do |key|
      matcher = @config["matchers"][key]
      require_relative @config["matchers_path"] + matcher["file"]
      curr_mod = Module.const_get(matcher["module_name"])
      mod_obj = curr_mod.send(:new, @config)
      @matchers << mod_obj
    end
  end

  def run_matchers(match_string)
    @matchers.each do |m|
      my_match = m.get_matcher(match_string)
      return my_match if my_match != nil
    end
    return nil
  end


  #TEMPLATE METHODS

  def lookup_author_for_entry(entry)
    my_id = entry["author"]
    @users.find {|u| u["id"] == my_id}
  end

  def lookup_media_for_entry(entry)
    my_id = entry["featured_media"]
    @media.find {|m| m["id"] == my_id}
  end

  def get_id_for_tag(tag_string)
    my_tag = @tags.find{|t| t["name"] == tag_string}
    my_tag != nil ? my_tag["id"] : nil
  end



  def pretty_date(entry)
    DateTime.parse(entry["modified_gmt"]).to_time.strftime("%B %d, %Y")
  end

  #POSTS BUILDING

  def build_posts
    `mkdir #{@config["output_path"] + "posts/"} `
    @posts.each do |post|
      post["content_hash"] = post["template"]["helper"]["obj"].run_helpers(post)
      post["content_hash"]["rendered_entry"] = render_entry_html(post)
      layout_html = render_layout(post)
      final_html = copy_and_replace_images(layout_html, post["slug"]+"/")
      file_path = write_entry_to_file(post, final_html)
    end
  end


  #PAGE BUILDING

  def build_pages
    render_css
    build_assets
    @pages.each do |page|
      #helper function added in load_helpers, called in initialie
      page["content_hash"] = page["template"]["helper"]["obj"].run_helpers(page)
      page["content_hash"]["rendered_entry"] = render_entry_html(page)
      layout_html = render_layout(page)
      final_html = copy_and_replace_images(layout_html, page["slug"]+"/")
      file_path = write_entry_to_file(page, final_html)

    end
  end

  def build_assets
    `cp -r #{@config["assets_path"]} #{@config["output_path"] + "."}`
    #@config["templates"].keys.each do |key|

     # template = @config["templates"][key]
     # if template["assets_dir"] && Dir.exists?(@config["assets_path"] + template["assets_dir"])
     #   binding.pry
     #   assets_out = @config["output_path"] + template["assets_dir"]
     #   assets_in = @config["assets_path"] + template["assets_dir"]
     #   `mkdir -p #{assets_out}`
     #   `cp -r #{assets_in} #{@config["output_path"]+"."}`

     # end
    #end
  end

  def render_css
    `mkdir #{@config["output_path"]+"css/"}`
    Dir.children(@config["css_path"]).each do |filename|
      my_match = /.*\.erb$/.match(filename)
      if !my_match.nil?
        f = File.open(@config["css_path"]+filename, "r")
        file_contents = f.read
        f.close
        my_css = erb2css(file_contents)
        filename2 = filename.gsub(/\.erb$/, "")
        File.write(@config["output_path"] + @config["css_path"] + filename2, my_css)
      else
       `cp #{@config["css_path"]+filename} #{@config["output_path"] + @config["css_path"] + filename}`
      end
    end
  end

  def erb2css(erbfile_contents)
    rcss = ERB.new(erbfile_contents)
    return rcss.result_with_hash({"globals" => @globals})

  end


  def pull_template_erb(template_file_name)
    if @config["template_path_set"]
     my_template_path = @config["template_path"] + template_file_name
    else
     my_template_path = "./" + template_file_name
    end
    template_file = File.open(my_template_path, "r")
    file_erb = template_file.read
    template_file.close
    return file_erb
  end

   def render_entry_html(entry)
     entry_erb = pull_template_erb(entry["template"]["in"])
     entry_rhtml = ERB.new(entry_erb)
     #helper function content is rendered in entry["content_hash"]
     return entry_rhtml.result_with_hash(entry)
  end

  def render_layout(entry)
    layout_erb = pull_template_erb(@config["templates"]["layout_default"]["in"])
    layout_rhtml = ERB.new(layout_erb)
    return layout_rhtml.result_with_hash(entry)
  end

  def outfile_name(entry)
    template = entry["template"]
    if match = /\$(.*)\$/.match(template["out"])
        return template["out"].gsub(match[0], entry[match[1]])
    end
    return template["out"]

  end


  def write_entry_to_file(entry, html)
    if entry["template"].has_key? "directory"
      output_file_path = @config["output_path"] + entry["template"]["directory"] + outfile_name(entry)
    else
      output_file_path = @config["output_path"] + outfile_name(entry)
    end
    out_file = File.open(output_file_path, "w")
    File.write(out_file, html)
    out_file.close
    return output_file_path
 end

  def create_new_image_path(old_image_path, new_image_directory_path, new_filename)
    #TODO: check for entry_image_dir and create if need to

    #`mkdir #{@config["output_path"] + @config["images_directory"]}` if !Dir.exists?(@config["output_path"] + @config["images_directory"])
    `mkdir -p #{new_image_directory_path}` if !Dir.exists?(new_image_directory_path)
    resp = Faraday.get(old_image_path)
    File.open(new_image_directory_path+new_filename, 'wb') { |wp| wp.write(resp.body) }
    return true
  end

  def copy_and_replace_images(page_html, entry_image_dir)
  # since the #to_html method dumps an entire html doc, need to run this method after layout+page have been generated
    ndoc = Nokogiri::HTML(page_html)
    images = ndoc.search("img")
    images.each do |i|
       #check if this image is from our wordpress
       #match against @config["replace_image_urls"]
       #easy with this? Regexp.new @config["json_api"] + "uploads"
       #create_new_image_path(i.get_attribute "src", my_regex, entry_image_dir)
       i.remove_attribute "srcset" if i.get_attribute "srcset"
       old_path = i.get_attribute "src"
       new_filename = run_matchers(old_path)
       if new_filename != nil
         image_path = @config["images_directory"] + entry_image_dir
         write_path = @config["output_path"] + image_path
         new_image_path = create_new_image_path(old_path, write_path, new_filename)
         i.set_attribute("src", @globals['site_url']+image_path+new_filename)
       end
    end
     ndoc.to_html
  end



end

jrb = Jagular.new
binding.pry
