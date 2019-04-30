require "./application"

module Engine::API
  class Users < Application
    base "/api/v1/users/"

    before_action :check_authorization, only: [:update]
    before_action :check_admin, only: [:index, :destroy, :create]

    # Factored into seperate auth service
    # before_action :doorkeeper_authorize!

    # Admins can see a little more of the users data
    # ADMIN_DATA = User::PUBLIC_DATA.dup
    # ADMIN_DATA[:only] += [:support, :sys_admin, :email, :phone]

    def index
      query = User.elastic.query(params)
      query.must_not({"doc.deleted" => [true]})

      authority_id = params[:authority_id]?
      query.filter({"doc.authority_id" => [authority_id]}) if authority_id

      results = User.elastic.search(query) do |user|
        # FIXME: render json subset
        # user.as_json(ADMIN_DATA)
        user
      end

      render json: results
    end

    def show
      user = User.find(id)

      # We only want to provide limited "public" information
      if current_user.sys_admin
        # FIXME: render json subset
        # render json: user.as_json(ADMIN_DATA)
        render json: user
      else
        # FIXME: render json subset
        # render json: user.as_json(User::PUBLIC_DATA)
        render json: user
      end
    end

    def current
      render json: current_user
    end

    def create
      user = User.new(params)
      user.authority = current_authority
      save_and_respond user
    end

    ##
    # Requests requiring authorization have already loaded the model
    def update
      @user.assign_attributes(safe_params)
      @user.save
      render json: @user
    end

    # Make this available when there is a clean up option
    def destroy
      @user = User.find(id)

      if defined?(::UserCleanup)
        @user.destroy
        head :ok
      else
        ::Auth::Authentication.for_user(@user.id).each do |auth|
          auth.destroy
        end
        @user.destroy
      end
    end

    protected def safe_params(params)
      user = required_params(params, :user)

      if current_user.sys_admin
        user.select!(
          :name, :first_name, :last_name, :country, :building, :email, :phone, :nickname,
          :card_number, :login_name, :staff_id, :sys_admin, :support, :password, :password_confirmation
        )
      else
        user.select!(
          :name, :first_name, :last_name, :country, :building, :email, :phone, :nickname
        )
      end
    end

    protected def check_authorization
      # Find will raise a 404 (not found) if there is an error
      @user = User.find!(params["id"]?)

      # FIXME: previously, current_user pulled off manager
      # Likely new middleware will decode user from jwt
      user = current_user

      # Does the current user have permission to perform the current action
      head :forbidden unless @user.id == user.id || user.sys_admin
    end
  end
end
