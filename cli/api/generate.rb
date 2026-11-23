# Generate Foreman's Go wire models and methods from the checked-in OpenAPI 3.1
# document. Only generation needs Ruby (standard library) and gofmt.
require "yaml"
require "open3"

spec = YAML.safe_load(File.read(File.join(__dir__, "../../docs/design/public-api.openapi.yaml")))
components = spec.fetch("components")
models = components.fetch("schemas").dup
operations = []
forms = []
grants = []

def go_name(name)
  acronyms = {"id" => "ID", "ssh" => "SSH", "uri" => "URI"}
  name.split(/[_-]/).map { |part| acronyms.fetch(part.downcase) { part.sub(/^./, &:upcase) } }.join
end

def ref(schema)
  schema.fetch("$ref").split("/").last
end

def go_type(schema)
  return go_name(ref(schema)) if schema.key?("$ref")
  type = schema["type"]
  return "*" + go_type(schema.merge("type" => (type - ["null"]).fetch(0))) if type.is_a?(Array) && type.include?("null")
  return "string" if schema["const"].is_a?(String)
  case type
  when "string" then "string"
  when "integer" then "int64"
  when "boolean" then "bool"
  when "array" then "[]" + go_type(schema.fetch("items"))
  else raise "Unsupported OpenAPI type #{schema.inspect}"
  end
end

def declaration(name, schema)
  return "type #{name} = #{go_type(schema)}\n" unless schema["type"] == "object"
  required = schema.fetch("required", [])
  fields = schema.fetch("properties").map do |wire, definition|
    type = go_type(definition)
    optional = !required.include?(wire)
    type = "*" + type if optional && !type.start_with?("*")
    "    #{go_name(wire)} #{type} `json:\"#{wire}#{',omitempty' if optional}\"`"
  end
  "type #{name} struct {\n#{fields.join("\n")}\n}\n"
end

spec.fetch("paths").each do |path, methods|
  methods.each do |method, op|
    name = go_name(op.fetch("operationId"))
    args = ["ctx context.Context"]
    fields = ["method: #{method.upcase.inspect}"]
    fields << "bearer: true" if op.fetch("security", []).any? { |s| s.key?("foremanToken") }
    fields << "basic: true" if op.fetch("security", spec.fetch("security")).any? { |s| s.key?("serviceCredential") }
    route = path.inspect
    op.fetch("parameters", []).each do |p|
      p = components.fetch("parameters").fetch(ref(p)) if p.key?("$ref")
      wire = p.fetch("name")
      case p.fetch("in")
      when "path"
        args << "#{wire} string"
        route = route.sub("{#{wire}}", "\" + url.PathEscape(#{wire}) + \"").sub(/ \+ ""$/, "")
      when "query"
        raise "Unsupported query #{wire}" unless wire == "cursor"
        args << "cursor string"
        fields << "cursor: cursor"
      when "header"
        raise "Unsupported header #{wire}" unless wire == "Idempotency-Key"
        args << "key string"
        fields << "key: key"
      else raise "Unknown parameter #{p.inspect}"
      end
    end
    fields << "path: #{route}"
    if op.key?("requestBody")
      media, content = op.fetch("requestBody").fetch("content").first
      schema = content.fetch("schema")
      if schema.key?("oneOf")
        grants = schema.fetch("oneOf").map { |s| go_name(ref(s)) }
        type = "TokenGrant"
        forms.concat(grants)
      elsif schema.key?("$ref")
        type = go_name(ref(schema))
      else
        type = name + "Body"
        models[type] = schema
      end
      args << "body #{type}"
      case media
      when "application/x-www-form-urlencoded"
        forms << type unless type == "TokenGrant"
        fields << "form: body.form()"
        fields << "oauthOperation: #{name.inspect}"
      when "application/json" then fields << "body: body"
      else raise "Unsupported media type #{media}"
      end
    end
    responses = op.fetch("responses").select { |code, _| code.match?(/^2\d\d$/) }
    success = responses.map { |_, r| r.dig("content", "application/json", "schema") }
    if success == [nil]
      result = "struct{}"
      fields << "emptyResponse: true"
    elsif success.length == 1 && success.first.key?("$ref")
      result = go_name(ref(success.first))
    else
      # For multiple success statuses return the common fields as required,
      # the status-specific fields as optional, and preserve status and headers.
      objects = success.map { |s| s.key?("$ref") ? models.fetch(ref(s)) : s }
      result = name + "Result"
      models[result] = {"type" => "object", "required" => objects.map { |s| s.fetch("required", []) }.reduce(:&),
                        "properties" => objects.map { |s| s.fetch("properties") }.reduce(:merge)}
    end
    fields << "success: []int{#{responses.keys.join(', ')}}"
    operations << "// #{name} — #{op.fetch('summary')}.\nfunc (c *Client) #{name}(#{args.join(', ')}) (*Response[#{result}], error) {\n    return call[#{result}](ctx, c, request{#{fields.join(', ')}})\n}\n"
  end
end

source = ["// Code generated from docs/design/public-api.openapi.yaml by go generate. DO NOT EDIT.",
          "package api", 'import ("context"; "net/url")']
models.each { |name, schema| source << declaration(go_name(name), schema) }
source << "type TokenGrant interface { form() url.Values; tokenGrant() }"
grants.each { |name| source << "func (#{name}) tokenGrant() {}" }
forms.each do |name|
  schema = models.fetch(name)
  lines = ["func (v #{name}) form() url.Values {", "    values := url.Values{}"]
  schema.fetch("properties").each do |wire, definition|
    raise "Unsupported form field" unless %w[string ScopeString].include?(go_type(definition))
    field = "v." + go_name(wire)
    if schema.fetch("required", []).include?(wire)
      lines << "    values.Set(#{wire.inspect}, #{field})"
    else
      lines << "    if #{field} != nil { values.Set(#{wire.inspect}, *#{field}) }"
    end
  end
  source << (lines + ["    return values", "}"]).join("\n")
end
source.concat(operations)
output, status = Open3.capture2("gofmt", stdin_data: source.join("\n\n"))
abort("gofmt failed") unless status.success?
File.write(File.join(__dir__, "client.gen.go"), output)
