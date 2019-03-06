require 'sinatra'
require 'fileutils'
require 'erb'
require 'zip'
require 'nokogiri'
require 'json'
require 'rexml/document'
require 'active_support'
require 'active_support/core_ext'

include FileUtils::Verbose

get '/' do
    erb :index
end

post '/' do
	# Hard coding FHIR version to STU3. IMPROVEMENT: Support different versions (or just update to R4).
	fhirversion = '3.0.1'

	# Grab IG
  ig_tempfile = params[:ig][:tempfile]
  ig_filename = Random.new_seed.to_s + '_' + params[:ig][:filename]
  cp(ig_tempfile.path, File.join('public', 'uploads', "#{ig_filename}"))

  # Create temp workspace directory
  FileUtils.remove_dir('ig', true)
  FileUtils.mkdir('ig')

  # Build layout
  FileUtils.mkdir(File.join('ig', 'pages'))
  FileUtils.mkdir(File.join('ig', 'resources'))

	# Populate Pages
	Zip::File.open(File.join('public', 'uploads', "#{ig_filename}")) do |zip_file|
	  zip_file.each do |entry|
	  	zip_file.each do |f|
	      f_path = File.join('ig', 'pages', f.name)
	      FileUtils.mkdir_p(File.dirname(f_path))
	      zip_file.extract(f, f_path) unless File.exist?(f_path)
	    end
	  end
	end

	# Populate Resources
	Dir.glob(File.join('ig', 'pages', 'artifacts', '*.xml')).each do |f|
		next if f.include? 'example' # VRDR

	  xmlfile = File.read(f)
	  xmlfile_f = File.new(File.join('ig', 'resources', File.basename(f)), 'w')

	  xmlfile.gsub!(/<title value=" (.*?)".?\/>/, '<title value="\1" />')

	  xmlfile_f.write xmlfile
	  xmlfile_f.close
	end

	# Apply fixes to all resources
	Dir.glob(File.join('ig', 'resources', '*.xml')).each do |f|
	  xmlfile = File.read(f)
	  xmlfile_f = File.new(f, 'w')

	  xmlfile.gsub!(/<title value=" (.*?)".?\/>/, '<title value="\1" />')

	  xmlfile_f.write xmlfile
	  xmlfile_f.close
	end

	# Remove duplicate resources
	if params[:deleteduplicateresources] == 'on'
		resource_lookup = {}
		Dir.glob(File.join('ig', 'resources', '*.xml')).each do |f|
			xmlfile = File.read(f)

			resource_id = /<id value=\"(.*?)\".?\/>/.match(xmlfile)[1] unless resource_id = /<id value=\"(.*?)\".?\/>/.match(xmlfile).nil?

			# Resource exist yet?
			if resource_lookup.key? resource_id
				# Only keep the most recent version
				existing_xmlfile = File.read(resource_lookup[resource_id])
				if /<lastUpdated value=\"(.*?)\".?\/>/.match(existing_xmlfile).nil? || /<lastUpdated value=\"(.*?)\".?\/>/.match(xmlfile).nil?
					if resource_lookup[resource_id] > f
						File.delete(f)
					else
						File.delete(resource_lookup[resource_id])
						resource_lookup[resource_id] = f
					end
				else
					existing_updated = /<lastUpdated value=\"(.*?)\".?\/>/.match(existing_xmlfile)[1]
					updated = /<lastUpdated value=\"(.*?)\".?\/>/.match(xmlfile)[1]
					if DateTime.parse(existing_updated) > DateTime.parse(updated)
						File.delete(f)
					else
						File.delete(resource_lookup[resource_id])
						resource_lookup[resource_id] = f
					end
				end
			else
				resource_lookup[resource_id] = f
			end
		end
	end

	# Create index.html
	newindex = File.read(File.join('ig', 'pages', "#{params[:igindex] || 'index.html'}"))
	newindex_f = File.new(File.join('ig', 'pages', 'index.html'), 'w')
	newindex_f.write newindex
	newindex_f.close

	# Convert all HTML pages to XHTML
	Dir.glob(File.join('ig', 'pages', '*.html')).each do |f|
	  htmlfile = File.read(f)
	  htmlfile_f = File.new(f, 'w')
	  htmlfile_f.write Nokogiri::HTML(htmlfile).to_xhtml
	  htmlfile_f.close
	end

	# Figure out internal pathname
	directories = Dir.glob(File.join('ig', 'pages', 'guide', '*')).select { |f| File.directory? f }
	iglabel = File.basename(directories.first)

	# Get rid of unecessary page files
	File.delete(File.join('ig', 'pages', 'guide', "#{iglabel}", 'files', 'styles', 'ballotable', 'master.html')) if File.exist?(File.join('ig', 'pages', 'guide', "#{iglabel}", 'files', 'styles', 'ballotable', 'master.html'))

	# Build list of dependencies
	dependencies = []
	dep_params = params.select { |key, value| key.to_s.start_with? 'dep' }
	dep_params = Hash[dep_params.sort_by { |k, v| k.partition("-").last.to_i }]
	dep_len = dep_params.length / 3
	(0..dep_len-1).each do |n|
		dep = {}
		dep['name'] = dep_params['depname-' + n.to_s]
		dep['location'] = dep_params['deplocation-' + n.to_s]
		dep['version'] = dep_params['depversion-' + n.to_s]
		dependencies << dep
	end

	# Build namespace of params for rendering ERB templates
  ns = Namespace.new(igname: params[:igname],
    				         iglabel: iglabel,
    				         igtitle: params[:igtitle],
										 igdescription: params[:igdescription],
										 igurl: params[:igurl],
    				         igpublisher: params[:igpublisher],
    				         igindex: params[:igindex] || 'index.html',
										 igfile: params[:igfile],
										 dependencies: dependencies,
    				         fhirversion: fhirversion,
    				         npmname: params[:npmname],
    				         canonicalbase: params[:canonicalbase])

	# Apply fixes to root StructureDefinition
	igcontents = Nokogiri::XML(File.read(File.join('ig', 'resources', "#{params[:igfile]}"))).root.to_xml
	igcontents.gsub!("\n", '')
	igcontents.gsub!(/<url value=\".*?\".?\/>/, "<url value=\"#{params[:igurl]}\" />")
	igcontents.gsub!(/<name value=\".*?\".?\/>/, "<name value=\"#{params[:igname]}\" />")
	igcontents.gsub!(/<description value=\".*?\".?\/>/, "<description value=\"#{params[:igdescription]}\" />")
	# Add in dependencies
	ig_dependencies = ''
	dependencies.each do |ig_dep|
		ig_dependencies +=	"<dependency><type value=\"reference\"/><uri value=\"#{ig_dep['location']}\"/></dependency>"
	end
	igcontents.gsub!(/<fhirVersion value=\".*?\".?\/>/, "<fhirVersion value=\"#{fhirversion}\" /><id value=\"#{params[:igname]}\" /><publisher value=\"#{params[:igpublisher]}\" />" + ig_dependencies)
	igcontents.gsub!("<ImplementationGuide xmlns='http://hl7.org/fhir'>", "<ImplementationGuide xmlns='http://hl7.org/fhir' xmlns:xsi='http://www.w3.org/2001/XMLSchema-instance'>")
	igcontents.sub!(/<page>(.*)<\/page>/, '<page>' + "<title value=\"#{params[:igtitle]}\" /><kind value=\"page\" /><source value=\"index.html\" />" + '\1</page>')
	doc = REXML::Document.new(igcontents)
	out = ''
	formatter = REXML::Formatters::Pretty.new(2)
	formatter.write(doc, out)
	ig_f = File.new(File.join('ig', 'resources', "#{params[:igfile]}"), 'w')
	ig_f.write out
	ig_f.close

	# Apply fixes to all pages
	Dir.glob(File.join('ig', 'pages', '**', '*.*ml')).each do |f|
	  if f.include?('artifacts') && f.include?('html-example')
	  	File.delete(f) if File.exist?(f)
	  else
		htmlfile = File.read(f)
		htmlfile_f = File.new(f, 'w')

		htmlfile.gsub!('STU3', 'stu3')
		htmlfile.gsub!(/\?v=.*?"/, '"')
		htmlfile.gsub!(/href="\/"/, '')
		htmlfile.gsub!('<a href=""></a>', '')
		htmlfile.gsub!(/hl7.org/, 'www.hl7.org')
		htmlfile.gsub!(/<nav class="navbar navbar-default" role="navigation">/, '<!--status-bar--><nav class="navbar navbar-default" role="navigation">')
		htmlfile.gsub!(/<footer>/, '<footer igtool="footer">')

		htmlfile_f.write htmlfile
		htmlfile_f.close
	  end
	end

	# HTML page names MUST correspond to resource types + ids! Duplicate pages so they match what the publisher wants.
	# IMPROVEMENT: Potentially just rename pages. Might get tricky due to references in other pages.
	if params[:correctpagenames] == 'on'
		Dir.glob(File.join('ig', 'resources', '*.xml')).each do |f|
			xmlfile = File.read(f)
			if xmlfile.start_with?('<StructureDefinition')
				resource_id = /<id value=\"(.*?)\".?\/>/.match(xmlfile)[1]
				# Find (potential) corresponding page
				found = false
				Dir.glob(File.join('ig', 'pages', '*.html')).each do |f|
					htmlfile = File.read(f)
					if htmlfile.include? resource_id
						htmlfile_f = File.new(File.join('ig', 'pages', "StructureDefinition-#{resource_id}.html"), 'w')
						htmlfile_f.write htmlfile
						htmlfile_f.close
						found = true
						break
					end
				end
				unless found
					# Didn't find page, try harder
					Dir.glob(File.join('ig', 'pages', '*.html')).each do |f|
						htmlfile = File.read(f)
						if htmlfile.include? resource_id.gsub(/#{params[:igname]}-/i, '').gsub('-', '')
							htmlfile_f = File.new(File.join('ig', 'pages', "StructureDefinition-#{resource_id}.html"), 'w')
							htmlfile_f.write htmlfile
							htmlfile_f.close
							break
						end
					end
				end
			end
		end
	end

  # Build README.md
  readme_file = File.open(File.join('ig', 'README.md'), "w+")
  readme_template = File.read(File.join('templates', 'README.md.erb'))
  readme_file << ERB.new(readme_template, nil, '-').result(ns.get_binding)
  readme_file.close

  # Build ig.json
  ig_json_file = File.open(File.join('ig', 'ig.json'), "w+")
  ig_json_template = File.read(File.join('templates', 'ig.json.erb'))
  ig_json_file << JSON.pretty_generate(JSON.parse(ERB.new(ig_json_template, nil, '-').result(ns.get_binding)))
  ig_json_file.close

	# Zip and return results
	FileUtils.rm_rf('ig.zip') if File.exist?('ig.zip')
	zf = ZipFileGenerator.new('ig', 'ig.zip')
  zf.write()
  FileUtils.rm_rf('ig')

  send_file 'ig.zip'
end

class Namespace
  def initialize(hash)
    hash.each do |key, value|
      singleton_class.send(:define_method, key) { value }
    end
  end
  def get_binding
    binding
  end
end

class ZipFileGenerator
  def initialize(input_dir, output_file)
    @input_dir = input_dir
    @output_file = output_file
  end
  def write
    entries = Dir.entries(@input_dir) - %w[. ..]
    ::Zip::File.open(@output_file, ::Zip::File::CREATE) do |zipfile|
      write_entries entries, '', zipfile
    end
  end
  private
  def write_entries(entries, path, zipfile)
    entries.each do |e|
      zipfile_path = path == '' ? e : File.join(path, e)
      disk_file_path = File.join(@input_dir, zipfile_path)

      if File.directory? disk_file_path
        recursively_deflate_directory(disk_file_path, zipfile, zipfile_path)
      else
        put_into_archive(disk_file_path, zipfile, zipfile_path)
      end
    end
  end
  def recursively_deflate_directory(disk_file_path, zipfile, zipfile_path)
    zipfile.mkdir zipfile_path
    subdir = Dir.entries(disk_file_path) - %w[. ..]
    write_entries subdir, zipfile_path, zipfile
  end
  def put_into_archive(disk_file_path, zipfile, zipfile_path)
    zipfile.add(zipfile_path, disk_file_path)
  end
end

