class Jagular


#YAMLizedEntry
  #only store:
  #  slug --> if slug changed, this will cause a delete and rebuild
  #  modified_gmt
  #  marked (used by the look_for_p*_changed methods 
  #  (not needed) slug is name of image directory


#Entry objects
  #morphisims:
  #Page: entry_data, template(in), helpers/filters, output_path, images_folder 
  #Post: entry_data, filter_marks, images_folder 
    #Both pages and posts need handles that respond to calls from render_template_html and merge_with_layout
    
#Entry collection
# use a lookup based upon slug

  #Helper
    #run_helper -- runs methods for building page
    #add_filters -- returns a list of filter_callables to be run by Jagular


  #required files:
  #config.yaml
  #pages.yaml
  #posts.yaml


  def initialize
    load_yaml_files
    
    #set @pages_json, @posts_json
  end
  
  #copied to jag3
  def update_posts_and_pages
    page_changes = []
    pages_changes << look_for_pages_changed
    #delete_yaml_pages_not_marked
    #update_posts if hash_contents(@posts_json) != @stored_posts_json_hash
    #page_changes << look_for_pages_changed_by_posts
    #update_pages(page_changes.uniq) if !page_changes.empty?
    update_posts_and_pages_hashes
  
  end

  def look_for_pages_changed
    results_arr = []
    if hash_contents(@pages_json) != @stored_pages_json_hash
      json_pages_arr.each do |jp|
        #removing side effect: page_entry_changed? marks @pages_from_yaml[jp.slug]
        #WHAT are the conditons we coudl get by comparing yaml_pages to json_pages?
        #yaml_page_doesnt_exit
        #yaml_page_same
        #yaml_different
        #diff = compare_json_page_to_yaml_page(jp)
        #case diff
        #when :yaml_page_doesnt_exist
          #add to rendering list
          #nothing to mark
        #when :yaml_page_same
          #no re-render
          #mark as checked
        #when :yaml_different
          #add_to_rendering_list
          #mark as checked
        #end 
        if page_entry_changed_or_new?(jp)
          results_arr << jp.slug
          mark_yaml_page(jp)
        end
      end   
    end
    return results_arr.uniq
  end

  def look_for_pages_changed_by_posts
    posts_changed = look_for_posts_changed
    return pages_by_filter(posts_changed)
  end

  def pages_by_filter(posts_arr)
    pages_affected = []
    posts_arr.each do |post|
      @filters.each do |page_filter|
        if page_filter.run_filter(post).include? post
          pages_affected << page_filter.page
        end
      end
    end
  end

  def update_posts
    @posts.each do |post|
      post_html = render_template_html(post)
      render_with_layout(post, post_html)
    end
    store_posts_yaml
  end

  def update_pages
    @pages.each do |p|
      render_page(p)
    end
    store_pages_yaml
  end

  def render_page(page)
    page_hash = run_helper(page)

    page_html = render_template_html(page, page_hash)
    render_with_layout(page, page_html)
  end 
end

