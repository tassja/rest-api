require "action-controller"
require "placeos-models"
require "uuid"

require "../error"
require "../utilities/*"

module PlaceOS::Api
  private abstract class Application < ActionController::Base
    macro inherited
      Log = ::PlaceOS::Api::Log.for(self)
    end

    # Helpers for controller responses
    include Utils::Responders

    # Helpers for determining picking off user from JWT, authorization
    include Utils::CurrentUser

    # Helpers for defining scope checks on controller actions
    include Utils::Scopes

    # Core service discovery
    class_getter core_discovery : Discovery::Core { Discovery::Core.instance }

    # Default sort for elasticsearch
    NAME_SORT_ASC = {"name.keyword" => {order: :asc}}

    macro required_param(key)
      if (%value = {{ key }}).nil?
        return render_error(HTTP::Status::BAD_REQUEST, "Missing '{{ key }}' param")
      else
        %value
      end
    end

    def boolean_param(key : String, default : Bool = false, allow_empty : Bool = false) : Bool
      return true if allow_empty && params.has_key?(key) && params[key].nil?

      case params[key]?.presence.try(&.downcase)
      when .in?("1", "true")  then true
      when .in?("0", "false") then false
      else                         default
      end
    end

    def paginate_results(elastic, query, route = base_route)
      data = elastic.search(query)
      range_start = query.offset
      range_end = data[:results].size + range_start
      total_items = data[:total]
      item_type = elastic.elastic_index
      response.headers["X-Total-Count"] = total_items.to_s
      # response.headers["Accept-Ranges"] = item_type
      response.headers["Content-Range"] = "#{item_type} #{range_start}-#{range_end}/#{total_items}"

      if range_end < total_items
        params["offset"] = (range_end + 1).to_s
        params["limit"] = query.limit.to_s
        query_params = params.join('&') { |key, value| "#{key}=#{value}" }
        response.headers["Link"] = %(<#{route}?#{query_params}>; rel="next")
      end

      data[:results]
    end

    def set_collection_headers(size : Int32, content_type : String)
      response.headers["X-Total-Count"] = size.to_s
      response.headers["Content-Range"] = "#{content_type} 0-#{size - 1}/#{size}"
    end

    # Callbacks
    ###########################################################################

    before_action :set_request_id

    # All routes are authenticated, except root
    before_action :authorize!, except: [:root, :mqtt_user, :mqtt_access]

    # Simplifies determining user's requests in server-side logs
    before_action :set_user_id, except: [:root, :mqtt_user, :mqtt_access]

    # Set user_id from parsed JWT
    def set_user_id
      Log.context.set(user_id: user_token.id)
    end

    getter body : IO do
      request_body = request.body
      raise Error::NoBody.new if request_body.nil?
      request_body
    end

    getter request_id : String { UUID.random.to_s }

    # This makes it simple to match client requests with server side logs.
    # When building microservices, this ID should be propagated to upstream services.
    def set_request_id
      if request.headers.has_key?("X-Request-ID") && @request_id.nil?
        @request_id = request.headers["X-Request-ID"]
      end

      Log.context.set(
        client_ip: client_ip,
        request_id: request_id
      )

      response.headers["X-Request-ID"] = request_id
    end

    # Callback to enforce JSON request body
    protected def ensure_json
      unless request.headers["Content-Type"]?.try(&.starts_with?("application/json"))
        return render_error(HTTP::Status::NOT_ACCEPTABLE, "Accepts: application/json")
      end

      body
    end

    # Error Handlers
    ###########################################################################

    # 400 if request is missing a body
    rescue_from Error::NoBody do |_error|
      message = "missing request body"
      Log.debug { message }
      return render_error(HTTP::Status::BAD_REQUEST, message)
    end

    # 400 if unable to parse some JSON passed by a client
    rescue_from JSON::MappingError do |error|
      message = "Missing or extraneous properties in client JSON"
      Log.debug(exception: error) { message }

      if Api.production?
        return render_error(HTTP::Status::BAD_REQUEST, message)
      else
        return render_error(HTTP::Status::BAD_REQUEST, error.message, backtrace: error.backtrace?)
      end
    end

    rescue_from JSON::ParseException do |error|
      message = "Failed to parse client JSON"
      Log.debug(exception: error) { message }

      if Api.production?
        return render_error(HTTP::Status::BAD_REQUEST, message)
      else
        return render_error(HTTP::Status::BAD_REQUEST, error.message, backtrace: error.backtrace?)
      end
    end

    # 401 if no bearer token
    rescue_from Error::Unauthorized do |error|
      Log.debug { error.message }
      head :unauthorized
    end

    # 403 if user role invalid for a route
    rescue_from Error::Forbidden do |error|
      Log.debug { error.message }
      head :forbidden
    end

    # 404 if resource not present
    rescue_from RethinkORM::Error::DocumentNotFound do |error|
      Log.debug { error.message }
      head :not_found
    end

    # 400 if params fails validation before mutation
    rescue_from Error::InvalidParams do |error|
      model_errors = error.params.errors.map(&.to_s)
      Log.debug(exception: error) { {message: "Invalid params", model_errors: model_errors} }
      return render_error(HTTP::Status::BAD_REQUEST, "Invalid params: #{model_errors.join(", ")}")
    end
  end
end
