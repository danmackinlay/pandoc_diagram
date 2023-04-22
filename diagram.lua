--[[
diagram-generator – create images and figures from code blocks.

See copyright notice in file LICENSE.
]]
-- Module pandoc.system is required and was added in version 2.7.3
PANDOC_VERSION:must_be_at_least '3.0'

-- Version 3.1.2 reports Lua warnings via pandoc's reporting system.
if PANDOC_VERSION < '3.1.2' then
  warn '@on'
end

local system = require 'pandoc.system'
local utils = require 'pandoc.utils'
local stringify = utils.stringify
local with_temporary_directory = system.with_temporary_directory
local with_working_directory = system.with_working_directory

--- Returns a filter-specific directory in which cache files can be
--- stored, or nil if no such directory is available.
local function cachedir ()
  local cache_home = os.getenv 'XDG_CACHE_HOME'
  if not cache_home or cache_home == '' then
    local user_home = system.os == 'windows'
      and os.getenv 'USERPROFILE'
      or os.getenv 'HOME'

    if not user_home or user_home == '' then
      return nil
    end
    cache_home = pandoc.path.join{user_home, '.cache'} or nil
  end

  -- Create filter cache directory
  return pandoc.path.join{cache_home, 'pandoc-diagram-filter'}
end

--- Path holding the image cache, or `nil` if the cache is not used.
local image_cache = nil

local mimetype_for_extension = {
  pdf = 'application/pdf',
  png = 'image/png',
  svg = 'image/svg+xml',
}

local extension_for_mimetype = {
  ['application/pdf'] = 'pdf',
  ['image/svg+xml'] = 'svg',
  ['image/png'] = 'png'
}

--- Reads the contents of a file.
local function read_file (filepath)
  local fh = io.open(filepath, 'rb')
  local contents = fh:read('a')
  fh:close()
  return contents
end

--- Writes the contents into a file at the given path.
local function write_file (filepath, content)
  local fh = io.open(filepath, 'wb')
  fh:write(content)
  fh:close()
end

--
-- Diagram Engines
--

-- PlantUML engine; assumes that there's a `plantuml` binary.
local plantuml = {
  line_comment_start =  [[']],
  mime_types = {
    ['application/pdf'] = true,
    ['image/png'] = true,
    ['image/svg+xml'] = true,
  },
  compile = function (self, puml, mime_type)
    mime_type = mime_type or 'image/svg+xml'
    local formats = {
      ['application/pdf'] = 'pdf',
      ['image/png'] = 'png',
      ['image/svg+xml'] = 'svg',
    }
    local format = formats[mime_type]
    if not format then
      format, mime_type = 'svg', 'image/svg+xml'
    end
    local args = {'-t' .. format, "-pipe", "-charset", "UTF8"}
    return pandoc.pipe(self.execpath or 'plantuml', args, puml), mime_type
  end,
}

--- GraphViz engine for the dot language
local graphviz = {
  line_comment_start = '//',
  mime_types = {
    ['application/pdf'] = true,
    ['image/png'] = true,
    ['image/svg+xml'] = true,
  },
  compile = function (self, code, mime_type)
    mime_type = mime_type or 'image/svg+xml'
    local formats = {
      ['image/svg+xml'] = 'svg',
      ['application/pdf'] = 'pdf',
      ['image/jpeg'] = 'jpg',
      ['image/png'] = 'png',
    }
    local format = formats[mime_type]
    if not format then
      format, mime_type = 'svg', 'image/svg+xml'
    end
    return pandoc.pipe(self.execpath or 'dot', {"-T"..format}, code), mime_type
  end,
}

--- Mermaid engine
local mermaid = {
  line_comment_start = '%%',
  mime_types = {
    ['application/pdf'] = true,
    ['image/svg+xml'] = true,
    ['image/png'] = true,
  },
  compile = function (self, code, mime_type)
    mime_type = mime_type or 'image/svg+xml'
    local file_extension = extension_for_mimetype[mime_type]
    return with_temporary_directory("diagram", function (tmpdir)
      return with_working_directory(tmpdir, function ()
        local infile = 'diagram.mmd'
        local outfile = 'diagram.' .. file_extension
        write_file(infile, code)
        pandoc.pipe(
          self.execpath or 'mmdc',
          {"--pdfFit", "--input", infile, "--output", outfile},
          ''
        )
        return read_file(outfile), mime_type
      end)
    end)
  end,
}

--- TikZ
--

--- LaTeX template used to compile TikZ images. Takes additional
--- packages as the first, and the actual TikZ code as the second
--- argument.
local tikz_template = [[
\documentclass{standalone}
\usepackage{tikz}
%% begin: additional packages
%s
%% end: additional packages
\begin{document}
%s
\end{document}
]]

--- The TikZ engine uses pdflatex to compile TikZ code to an image
local tikz = {
  line_comment_start = '%%',

  mime_types = {
    ['application/pdf'] = true,
  },

  --- Compile LaTeX with TikZ code to an image
  compile = function (self, src, mime_type, user_opts)
    return with_temporary_directory("tikz", function (tmpdir)
      return with_working_directory(tmpdir, function ()
        local pkgs = stringify(user_opts['additional-packages'] or '')
        -- Define file names:
        local file_template = "%s/tikz-image.%s"
        local tikz_file = file_template:format(tmpdir, "tex")
        local pdf_file = file_template:format(tmpdir, "pdf")
        local tex_code = tikz_template:format(pkgs, src)
        write_file(tikz_file, tex_code)

        -- Execute the LaTeX compiler:
        pandoc.pipe(
          self.execpath or 'pdflatex',
          {'-output-directory', tmpdir, tikz_file},
          ''
        )

        -- ignore the passed MIME type; always return PDF output
        return read_file(pdf_file), 'application/pdf'
      end)
    end)
  end
}

--- Asymptote diagram engine
local asymptote = {
  line_comment_start = '%%',
  mime_types = {
    ['application/pdf'] = true,
  },
  compile = function (self, code, mime_type)
    return with_temporary_directory("asymptote", function(tmpdir)
      return with_working_directory(tmpdir, function ()
        local pdf_file = "pandoc_diagram.pdf"
        local args = {'-tex', 'pdflatex', "-o", "pandoc_diagram", '-'}
        pandoc.pipe(self.execpath or 'asy', args, code)
        return read_file(pdf_file), (mime_type or 'application/pdf')
      end)
    end)
  end,
}

local default_engines = {
  asymptote = asymptote,
  dot       = graphviz,
  mermaid   = mermaid,
  plantuml  = plantuml,
  tikz      = tikz,
}

--
-- Configuration
--
local function get_engine (name, engopts)
  local engine = default_engines[name] or
    select(2, pcall(require, stringify(engopts.package)))

  -- Sanity check
  if not engine then
    warn(PANDOC_SCRIPT_FILE, ": No such engine '", name, "'.")
    return nil
  elseif engopts == false then
    -- engine is disabled
    return nil
  end

  local execpath = engopts.execpath or os.getenv(name:upper() .. '_BIN')

  local mime_types = engine.mime_types or {}
  if pandoc.utils.type(engopts['mime-types']) == 'List' then
    -- If the setting is a list, then use only types defined in that List.
    engine.mime_types = {}
    for _, value in ipairs(engopts['mime-types']) do
      mime_types[stringify(value)] = true
    end
  elseif pandoc.utils.type(engopts['mime-types']) == 'table' then
    -- A table should enable/disable specific types
    for mime_type, setting in pairs(engopts['mime-types']) do
      mime_types[mime_type] = setting
    end
  elseif type(engopts['mime-types']) ~= 'nil' then
    -- Assume string, Inlines, and Blocks values specify the only
    -- acceptable MIME type.
    mime_types = {
      [stringify(engopts['mime-types'])] = true,
    }
  end

  return {
    execpath = execpath,
    compile = engine.compile,
    line_comment_start = engine.line_comment_start,
    mime_types = mime_types,
    opt = engopts.opt or {},
  }
end

-- Execute the meta data table to determine the paths. This function
-- must be called first to get the desired path. If one of these
-- meta options was set, it gets used instead of the corresponding
-- environment variable:
local function configure (meta)
  local conf = meta.diagram or {}
  meta.diagram = nil

  -- cache for image files
  if conf.cache then
    image_cache = conf['cache-dir']
      and stringify(conf['cache-dir'])
      or cachedir()
    pandoc.system.make_directory(image_cache, true)
  end

  -- engine configs
  local engine = {}
  for name, engopts in pairs(conf.engine or default_engines) do
    engine[name] = get_engine(name, engopts)
  end

  return {
    engine = engine,
    cache = image_cache and true,
    image_cache = image_cache,
  }
end


--
-- Format conversion
--

--- Converts a PDF to SVG.
local pdf2svg = function (imgdata)
  local pdf_file = os.tmpname() .. '.pdf'
  write_file(pdf_file, imgdata)
  local args = {
    '--export-type=svg',
    '--export-plain-svg',
    '--export-filename=-',
    pdf_file
  }
  return pandoc.pipe('inkscape', args, ''), os.remove(pdf_file)
end

local function properties_from_code (code, comment_start)
  local props = {}
  local pattern = comment_start:gsub('%p', '%%%1') .. '| ' ..
    '([-_%w]+): ([^\n]*)\n'
  for key, value in code:gmatch(pattern) do
    if key == 'fig-cap' then
      props['caption'] = value
    else
      props[key] = value
    end
  end
  return props
end

local function diagram_properties (cb, comment_start)
  local attribs = comment_start
    and properties_from_code(cb.text, comment_start)
    or {}
  for key, value in pairs(cb.attributes) do
    attribs[key] = value
  end

  -- Read caption attribute as Markdown
  local caption = attribs.caption
    and pandoc.read(attribs.caption).blocks
    or pandoc.Blocks{}
  local fig_attr = {
    id = cb.identifier ~= '' and cb.identifier or attribs.label,
    name = attribs.name,
  }
  local user_opt = {}

  for k, v in pairs(attribs) do
    local prefix, key = k:match '^(%a+)%-(%a[-%w]*)$'
    if prefix == 'fig' then
      fig_attr[key] = v
    elseif prefix == 'opt' then
      user_opt[key] = v
    end
  end

  return {
    ['alt'] = pandoc.utils.blocks_to_inlines(caption),
    ['caption'] = caption,
    ['fig-attr'] = fig_attr,
    ['filename'] = attribs.filename,
    ['image-attr'] = {
      height = attribs.height,
      width = attribs.width,
      style = attribs.style,
    },
    ['opt'] = user_opt,
  }
end

local function get_cached_image (hash)
  if not image_cache then
    return nil
  end
  for _, ext in ipairs{'pdf', 'svg', 'png'} do
    local filename = hash .. '.' .. ext
    local imgpath = pandoc.path.join{image_cache, filename}
    local success, imgdata = pcall(read_file, imgpath)
    if success then
      return imgdata, mimetype_for_extension[ext]
    end
  end
  return nil
end

local function cache_image (codeblock, imgdata, mimetype)
  -- do nothing if caching is disabled or not possible.
  if not image_cache then
    return
  end
  local ext = extension_for_mimetype[mimetype]
  local filename = pandoc.sha1(codeblock.text) .. '.' .. ext
  local imgpath = pandoc.path.join{image_cache, filename}
  write_file(imgpath, imgdata)
end

local preferred_mime_types = pandoc.List{'image/svg+xml', 'image/png'}
if (FORMAT == 'latex' or FORMAT == 'context') then
  preferred_mime_types = pandoc.List{'application/pdf', 'image/png'}
end

-- Executes each document's code block to find matching code blocks:
local function code_to_figure (conf)
  return function (block)
    -- Check if a converter exists for this block. If not, return the block
    -- unchanged.
    local diagram_type = block.classes[1]
    if not diagram_type then
      return nil
    end

    local engine = conf.engine[diagram_type]
    if not engine then
      return nil
    end

    -- Unified properties.
    local props = diagram_properties(block, engine.line_comment_start, conf)

    local preferred_mime_type = preferred_mime_types:find_if(function (pref)
        return engine.mime_types[pref]
    end)

    -- Try to retrieve the image data from the cache.
    local img, imgtype = get_cached_image(pandoc.sha1(block.text))

    if not img or not imgtype then
      -- No cached image; call the converter
      local success
      success, img, imgtype =
        pcall(engine.compile, engine, block.text, preferred_mime_type, props.opt)

      -- Bail if an error occurred; img contains the error message when that
      -- happens.
      if not success then
        warn(PANDOC_SCRIPT_FILE, ': ', tostring(img))
        return nil
      elseif not img then
        warn(PANDOC_SCRIPT_FILE, 'Diagram engine returned no image data.')
        return nil
      elseif not imgtype then
        warn(PANDOC_SCRIPT_FILE, 'Diagram engine did not return a MIME type.')
        return nil
      end

      -- If we got here, then the transformation went ok and `img` contains
      -- the image data.
      cache_image(block, img, imgtype)
    end

    -- Convert SVG if necessary.
    if imgtype == 'application/pdf' and not preferred_mime_types[imgtype] then
      img, imgtype = pdf2svg(img), 'image/svg+xml'
    end

    -- Use the block's filename attribute or create a new name by hashing the
    -- image content.
    local basename, _extension = pandoc.path.split_extension(
      props.filename or pandoc.sha1(img)
    )
    local fname = basename .. '.' .. extension_for_mimetype[imgtype]

    -- Store the data in the media bag:
    pandoc.mediabag.insert(fname, imgtype, img)

    -- Create a figure that contains just this image.
    local img_obj = pandoc.Image(props.alt, fname, "", props['image-attr'])
    return pandoc.Figure(pandoc.Plain{img_obj}, props.caption, props['fig-attr'])
  end
end

function Pandoc (doc)
  local conf = configure(doc.meta)
  return doc:walk {
    CodeBlock = code_to_figure(conf),
  }
end
