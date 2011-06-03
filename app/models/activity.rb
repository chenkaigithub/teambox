class Activity < ActiveRecord::Base

  belongs_to :target, :polymorphic => true
  belongs_to :comment_target, :polymorphic => true
  belongs_to :user
  belongs_to :project

  scope :for_task_lists, :conditions => "target_type = 'TaskList' || target_type = 'Task' || comment_target_type = 'TaskList' || comment_target_type = 'Task'"
  scope :for_conversations, :conditions => "target_type = 'Conversation' || comment_target_type = 'Conversation'"
  scope :for_tasks, :conditions => "target_type = 'Task' || comment_target_type = 'Task'"
  scope :in_targets, lambda {|targets| {:conditions => ["target_id IN (?) OR comment_target_id IN (?)", *(Array(targets).collect(&:id)*2)]}}

  scope :latest, :order => 'id DESC', :limit => Teambox.config.activities_per_page

  scope :in_projects, lambda { |projects| { :conditions => ["project_id IN (?)", Array(projects).collect(&:id) ] } }
  scope :limit_per_page, :limit => Teambox.config.activities_per_page
  scope :by_id, :order => 'id DESC'
  scope :by_updated, :order => 'updated_at desc'

  # COALESCE returns the first non null element and it's standard SQL
  scope :by_thread, :order => "COALESCE(last_activity_id, id) desc"
  scope :threads, :conditions => "target_type != 'Comment'"
  scope :before, lambda { |previous| { :conditions => ["id < ? AND (last_activity_id IS NULL OR last_activity_id < ?)", previous.last_id, previous.last_id] } }
  scope :after, lambda { |activity_id| { :conditions => ["id > ?", activity_id ] } }
  scope :from_user, lambda { |user| { :conditions => { :user_id => user.id } } }

  # We have to update the activity of the thread if such is the case
  after_create :ping_parent_activity


  def self.log(project,target,action,creator_id)
    project_id = project.try(:id)
    return if project.try(:is_importing)

    if target.is_a? Comment
      comment_target_type = target.target_type
      comment_target_id = target.target_id
    end
    
    activity = Activity.new(
      :project_id => project_id,
      :target => target,
      :action => action,
      :user_id => creator_id,
      :comment_target_type => comment_target_type,
      :comment_target_id => comment_target_id)
    activity.created_at = target.try(:updated_at) || target.try(:created_at)
    activity.save
    
    activity
  end

  # Returns the id of the activity itself or the activity's last children's activity if any
  def last_id
    last_activity_id || id
  end

  def self.remove_log(project,target,action)
    activity = where(:project_id => project.id, :target_id => target.id, :target_type => target.class.name, :action => action).first
    activity.destroy if activity
  end

  def refs_thread_comments
    if target.respond_to? :first_comment
      [target.first_comment] + target.recent_comments
    else
      []
    end
  end
  
  def refs_comment_target
    if comment_target.respond_to? :first_comment
      [comment_target,
       comment_target.first_comment,
       comment_target.user,
       comment_target.first_comment.try(:user)] + 
       comment_target.recent_comments + 
       comment_target.recent_comments.map(&:user)
    else
      [comment_target]
    end
  end

  def action_comment_type
    i = "#{action}#{target_type}"
    i +="#{comment_target_type}" if comment_target_type
    i.underscore
  end


  def action_type
    i = "#{action}#{target_type}"
    i.underscore
  end
    
  def action_type?(current_type)
    i = "#{action}#{target_type.singular_class_name}"
    i.underscore
    i == current_type
  end
  
  def target
    @target ||= target_id ? Kernel.const_get(target_type).find_with_deleted(target_id) : nil
  end
  
  def comment_target
    @comment_target ||= comment_target_id ? Kernel.const_get(comment_target_type).find_with_deleted(comment_target_id) : nil
  end
  
  def user
    target.user
  end

  def posted_date
    target.created_at
  end

  def downcase_type
    target.type.to_s.downcase
  end

  def user
    @user ||= user_id ? User.with_deleted.find_by_id(user_id) : nil
  end

  def thread
    @thread ||= if target.is_a?(Comment)
      comment_target
    else
      target
    end || project
  end

  def thread?
    %w(Conversation Task).include?(target_type)
  end

  def thread_id
    target_type == 'Comment' ? "#{comment_target_type}_#{comment_target_id}" : "#{target_type}_#{target_id}"
  end

  def activity_id
    if target_type == 'Comment'
      "#{target_type.downcase}_#{target_id}"
    elsif thread?
      "thread_#{target_type.downcase}_#{target_id}"
    else
      "activity_#{target_type.downcase}_#{target_id}"
    end
  end

  def self.for_projects(projects)
    in_projects(projects).limit_per_page.by_thread
  end

  def to_xml(options = {})
    options[:indent] ||= 2
    xml = options[:builder] ||= Builder::XmlMarkup.new(:indent => options[:indent])
    xml.instruct! unless options[:skip_instruct]

    xml.activity :id => id do
      xml.tag! 'action', action
      xml.tag! 'created-at', created_at.to_s(:db)
      xml.tag! 'updated-at', updated_at.to_s(:db)

      xml.user :id => user_id do
        xml.tag! 'username',   user.login
        xml.tag! 'first-name', user.first_name
        xml.tag! 'last-name',  user.last_name
        xml.tag! 'avatar-url', user.avatar_or_gravatar_url(:thumb)
        xml.tag! 'micro-avatar-url', user.avatar_or_gravatar_url(:micro)
      end

      xml.project :id => project_id do
        xml.tag! 'name',       project.name
        xml.tag! 'permalink',  project.permalink
      end

      xml.target :id => target.id do
        xml.tag! 'type', target.class
        target.to_xml(options.merge({ :skip_instruct => true }))
      end if target
    end
  end
  
  def to_push_data(options={})
    target_includes = [:project, :user]
    includes = [:target, :project, :user]
    case self.target_type
    when 'User'
      includes = []
      target_includes = []
    when 'Project'
      includes = [:user]
      target_includes = [:user]
    when 'Task'
      target_includes << :comments
      target_includes << :assigned
      target_includes << :task_list
    when 'Comment'
      target_includes << :target
    when 'Conversation'
      target_includes << :comments
    when 'Page'
      target_includes << :slots
      target_includes << :objects
    when 'Note'
      target_includes << :page
    when 'Divider'
      target_includes << :page
    end

    data = to_api_hash(:include => includes,
                       :emit_type => true,
                       :target_options => {
                         :emit_type => true,
                         :include => target_includes
                       })
    data.merge(options)
  end

  def is_first_comment?
    comment_target && comment_target.respond_to?(:first_comment) && comment_target.first_comment == target
  end

  def is_converted_comment?
    comment_target ? comment_target.respond_to?(:record_conversion) && comment_target.record_conversion : false
  end

  def push?
    target && target.respond_to?(:dont_push) ? !target.dont_push : true
  end

  def to_api_hash(options = {})
    base = {
      :id => id,
      :last_activity_id => last_activity_id,
      :action => action,
      :created_at => created_at.to_s(:api_time),
      :updated_at => updated_at.to_s(:api_time),
      :user_id => user_id,
      :project_id => project_id,
      :target_id => target_id,
      :target_type => target_type,
      :action_type => action_type,
      :comment_target_id => comment_target_id,
      :comment_target_type => comment_target_type,
      :activity_id => activity_id,
      :changes => action_type == 'create' ? target.attributes : target.previous_changes
    }
    
    base[:type] = self.class.to_s if options[:emit_type]
    
    if Array(options[:include]).include? :project
      base[:project] = {:name => project.name, :permalink => project.permalink}
    end
    
    if Array(options[:include]).include? :target
      base[:target] = target.to_api_hash(options[:target_options])
    end
    
    if Array(options[:include]).include? :user
      base[:user] = {
        :username => user.login,
        :first_name => user.first_name,
        :last_name => user.last_name,
        :avatar_url => user.avatar_or_gravatar_url(:thumb),
        :micro_avatar_url => user.avatar_or_gravatar_url(:micro)
      }
    end
    
    base
  end

  protected

  def ping_parent_activity
    if target.is_a? Comment and parent = Activity.last(:conditions => ["target_type = ? AND target_id = ?", comment_target_type, comment_target_id])
      parent.update_attribute :last_activity_id, id # touch activity related to that comment's thread
    end
  end

end
