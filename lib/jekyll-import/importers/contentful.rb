module JekyllImport
  module Importers
    class Contentful < Importer

      def self.require_deps
        JekyllImport.require_with_fallback(%w[
          rubygems
          contenful
          fileutils
          safe_yaml
          unidecode
        ])
      end

      def self.specify_options(c)
        c.option 'access_token', '--access_token ACCESS_TOKEN', 'Access token (default: "")'
        c.option 'space_id', '--space_id SPACE', 'Space ID (default: "")'
        c.option 'api_endpoint', '--api API_ENDPOINT', 'API Endpoint (default: "api.contentful.com")'
        c.option 'post_content_type', '--post_content_type CONTENT_TYPE', 'Posts Content Type (default: "posts")'
        c.option 'page_content_type', '--page_content_type CONTENT_TYPE', 'Pages Content Type (default: "pages")'
        c.option 'clean_entities', '--clean_entities', 'Whether to clean entities (default: true)'
        c.option 'more_excerpt', '--more_excerpt', 'Whether to use more excerpt (default: true)'
        c.option 'more_anchor', '--more_anchor', 'Whether to use more anchor (default: true)'
        c.option 'status', '--status STATUS,STATUS2', Array, 'Array of allowed statuses (default: ["publish"], other options: "draft", "private", "revision")'
      end

      # Main migrator function. Call this to perform the migration.
      #
      # dbname::  The name of the database
      # user::    The database user name
      # pass::    The database user's password
      # host::    The address of the MySQL database host. Default: 'localhost'
      # socket::  The database socket's path
      # options:: A hash table of configuration options.
      #
      # Supported options are:
      #
      # :clean_entities:: If true, convert non-ASCII characters to HTML
      #                   entities in the posts, comments, titles, and
      #                   names. Requires the 'htmlentities' gem to
      #                   work. Default: true.
      # :more_excerpt::   If true, when a post has no excerpt but
      #                   does have a <!-- more --> tag, use the
      #                   preceding post content as the excerpt.
      #                   Default: true.
      # :more_anchor::    If true, convert a <!-- more --> tag into
      #                   two HTML anchors with ids "more" and
      #                   "more-NNN" (where NNN is the post number).
      #                   Default: true.
      # :extension::      Set the post extension. Default: "html"
      # :status::         Array of allowed post statuses. Only
      #                   posts with matching status will be migrated.
      #                   Known statuses are :publish, :draft, :private,
      #                   and :revision. If this is nil or an empty
      #                   array, all posts are migrated regardless of
      #                   status. Default: [:publish].
      #
      def self.process(opts)
        options = {
          :access_token        => opts.fetch('access_token', ''),
          :space_id            => opts.fetch('space_id', ''),
          :api_endpoint        => opts.fetch('api', 'api.contentful.com'),
          :clean_entities      => opts.fetch('clean_entities', true),
          :more_excerpt        => opts.fetch('more_excerpt', true),
          :more_anchor         => opts.fetch('more_anchor', true),
          :extension           => opts.fetch('extension', 'html'),
          :post_content_type   => opts.fetch('post_content_type', 'posts'),
          :page_content_type   => opts.fetch('page_content_type', 'pages'),
          :status              => opts.fetch('status', ['publish']).map(&:to_sym) # :draft, :private, :revision
        }

        if options[:clean_entities]
          begin
            require 'htmlentities'
          rescue LoadError
            STDERR.puts "Could not require 'htmlentities', so the " +
                        ":clean_entities option is now disabled."
            options[:clean_entities] = false
          end
        end

        FileUtils.mkdir_p("_posts")
        FileUtils.mkdir_p("_drafts") if options[:status].include? :draft

	client = Contentful::Client.new(
	  access_token: options[:access_token],
	  space: options[:space_id],
	  api_url: options[:api_endpoint]
	)

        page_name_list = {}

	#client.entries(content_type: options[:page_content_type]).each do |page|
        #  if !page[:slug] or page[:slug].empty?
        #    page[:slug] = sluggify(page[:title])
        #  end
        #  page_name_list[ page[:id] ] = {
        #    :slug   => page[:slug],
        #    :parent => page[:parent]
        #  }
        #end

	client.entries(content_type: options[:post_content_type]).each do |post|
          process_post(post, db, options, page_name_list)
        end
      end


      def self.process_post(post, db, options, page_name_list)
        extension = options[:extension]

        title = post[:title]
        if options[:clean_entities]
          title = clean_entities(title)
        end

        slug = post[:slug]
        if !slug or slug.empty?
          slug = sluggify(title)
        end

        date = post[:date] || Time.now
        name = "%02d-%02d-%02d-%s.%s" % [date.year, date.month, date.day,
                                         slug, extension]
        content = post[:content].to_s
        if options[:clean_entities]
          content = clean_entities(content)
        end

        excerpt = post[:excerpt].to_s

        more_index = content.index(/<!-- *more *-->/)
        more_anchor = nil
        if more_index
          if options[:more_excerpt] and
              (post[:excerpt].nil? or post[:excerpt].empty?)
            excerpt = content[0...more_index]
          end
          if options[:more_anchor]
            more_link = "more"
            content.sub!(/<!-- *more *-->/,
                         "<a id=\"more\"></a>" +
                         "<a id=\"more-#{post[:id]}\"></a>")
          end
        end


        # Get the relevant fields as a hash, delete empty fields and
        # convert to YAML for the header.
        data = {
          'layout'        => post[:type].to_s,
          'status'        => post[:status].to_s,
          'published'     => post[:status].to_s == 'draft' ? nil : (post[:status].to_s == 'publish'),
          'title'         => title.to_s,
          'author'        => {
            'display_name'=> post[:author].to_s,
            'login'       => post[:author_login].to_s,
            'email'       => post[:author_email].to_s,
            'url'  => post[:author_url].to_s,
          },
          'author_login'  => post[:author_login].to_s,
          'author_email'  => post[:author_email].to_s,
          'author_url'    => post[:author_url].to_s,
          'excerpt'       => excerpt,
          'more_anchor'   => more_anchor,
          'wordpress_id'  => post[:id],
          'wordpress_url' => post[:guid].to_s,
          'date'          => date.to_s,
          'date_gmt'      => post[:date_gmt].to_s,
        }.delete_if { |k,v| v.nil? || v == '' }.to_yaml

        if post[:type] == 'page'
          filename = page_path(post[:id], page_name_list) + "index.#{extension}"
          FileUtils.mkdir_p(File.dirname(filename))
        elsif post[:status] == 'draft'
          filename = "_drafts/#{slug}.md"
        else
          filename = "_posts/#{name}"
        end

        # Write out the data and content to file
        File.open(filename, "w") do |f|
          f.puts data
          f.puts "---"
          f.puts Util.wpautop(content)
        end
      end


      def self.clean_entities( text )
        if text.respond_to?(:force_encoding)
          text.force_encoding("UTF-8")
        end
        text = HTMLEntities.new.encode(text, :named)
        # We don't want to convert these, it would break all
        # HTML tags in the post.
        text.gsub!("&amp;", "&")
        text.gsub!("&lt;", "<")
        text.gsub!("&gt;", ">")
        text.gsub!("&quot;", '"')
        text.gsub!("&apos;", "'")
        text.gsub!("&#47;", "/")
        text
      end


      def self.sluggify( title )
        title = title.to_ascii.downcase.gsub(/[^0-9A-Za-z]+/, " ").strip.gsub(" ", "-")
      end

      def self.page_path( page_id, page_name_list )
        if page_name_list.key?(page_id)
          [
            page_path(page_name_list[page_id][:parent],page_name_list),
            page_name_list[page_id][:slug],
            '/'
          ].join("")
        else
          ""
        end
      end

    end
  end
end
