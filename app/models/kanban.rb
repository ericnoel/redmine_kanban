class Kanban
  attr_reader :incoming_pane, :backlog_pane, :quick_pane, :canceled_pane, :finished_pane, :active_pane, :testing_pane, :selected_pane
  
  attr_accessor :incoming_issues
  attr_accessor :quick_issues
  attr_accessor :backlog_issues
  attr_accessor :selected_issues
  attr_accessor :active_issues
  attr_accessor :testing_issues
  attr_accessor :finished_issues
  attr_accessor :canceled_issues
  attr_accessor :settings
  attr_accessor :users
  attr_accessor :user
  # How is this Kanban built:
  # * :author - by who created the issue
  # * :assigned_to - by who is assigned the issue
  # * :watcher - by who is watching the issue
  attr_accessor :for

  attr_accessor :fill_backlog
  attr_accessor :fill_incoming

  def initialize(attributes={})
    @user = attributes[:user]
    @for = attributes[:for].to_a
    @for = [:assigned_to] unless @for.present?
    @fill_backlog = attributes[:fill_backlog] || false
    @fill_incoming = attributes[:fill_incoming] || false
    @incoming_pane = KanbanPane::IncomingPane.new
    @backlog_pane = KanbanPane::BacklogPane.new
    @quick_pane = KanbanPane::QuickPane.new
    @canceled_pane = KanbanPane::CanceledPane.new
    @finished_pane = KanbanPane::FinishedPane.new
    @active_pane = KanbanPane::ActivePane.new
    @testing_pane = KanbanPane::TestingPane.new
    @selected_pane = KanbanPane::SelectedPane.new
    
    @settings = Setting.plugin_redmine_kanban
    @users = get_users
  end

  def self.non_kanban_issues_panes
     ["incoming","backlog", "quick","finished","canceled"]
  end

  def self.kanban_issues_panes
    ['selected','active','testing']
  end

  def self.valid_panes
    kanban_issues_panes + non_kanban_issues_panes
  end

  def self.staffed_panes
    ['active','testing','finished','canceled']
  end

  def incoming_issues
    @incoming_issues ||= incoming_pane.get_issues(:user => @user, :for => @for)
  end

  def quick_issues
    @quick_issues ||= quick_pane.get_issues
  end

  def backlog_issues
    quick_issues # Needs to load quick_issues
    @backlog_issues ||= backlog_pane.get_issues(:exclude_ids => quick_issue_ids, :for => @for, :user => @user)
  end

  def backlog_issues_with_fill(already_found_ids = [])
    quick_issues # Needs to load quick_issues
    # * Clears the user, all issues should be found.
    # * Sets the limit to be how many are still needed
    # * adds extra exclude ids for issues that are in the backlog_issues already
    fill_to = @settings['panes']['backlog']['limit'].to_i - already_found_ids.length
    backlog_pane.get_issues(:exclude_ids => quick_issue_ids + already_found_ids,
                            :for => nil,
                            :user => nil,
                            :limit => fill_to)
  end

  def selected_issues
    @selected_issues ||= selected_pane.get_issues(:user => @user, :for => @for)
  end

  def active_issues
    @active_issues ||= active_pane.get_issues(:users => get_users, :for => @for)
  end

  def testing_issues
    @testing_issues ||= testing_pane.get_issues(:users => get_users, :for => @for)
  end

  def finished_issues
    @finished_issues ||= finished_pane.get_issues(:for => @for, :user => @user)
  end

  def canceled_issues
    @canceled_issues ||= canceled_pane.get_issues(:users => get_users, :for => @for, :user => @user)
  end

  # Display the testing issues filtered by user and/or project
  # * :testing - user and project
  # * :active - user and project
  # * :selected - project
  #
  # OPTIMIZE: could cache this to ivars
  [:testing, :active, :selected, :canceled].each do |pane|
    define_method("#{pane}_issues_for") {|options|
      project = options[:project]
      user = options[:user]

      if pane != :selected
        all_kanban_issues = send("#{pane}_issues")[user]
      else
        all_kanban_issues = send("#{pane}_issues")
      end

      issues = all_kanban_issues.collect {|kanban_issue|
        if kanban_issue.for_project?(project) || (roll_up_projects? && kanban_issue.for_project_descendant?(project))
          kanban_issue.issue
        end
      }.compact
      issues ||= []
      issues
    }
  end

  # OPTIMIZE: could cache this to ivars
  def backlog_issues_for(options={})
    project = options[:project]
    #    user = options[:user]
    
    if backlog_issues.present?
      issues = backlog_issues.collect {|priority, issues|
        issues.select {|issue|
          if roll_up_projects?
            issue.project_id == project.id || issue.project.is_descendant_of?(project)
          else
            issue.project_id == project.id
          end

        }
      }.flatten
    end
    issues ||= []

    # Fill the backlog issues until the plugin limit
    if @fill_backlog && issues.length < @settings['panes']['backlog']['limit'].to_i
      already_found_ids = issues.collect(&:id)
      if backlog_issues_with_fill(already_found_ids).present?
        issues += backlog_issues_with_fill(already_found_ids).collect {|priority, issues|
          issues.select {|issue|
            if roll_up_projects?
              issue.project_id == project.id || issue.project.is_descendant_of?(project)
            else
              issue.project_id == project.id
            end

          }
        }.flatten
      end
      
    end

    issues
  end

  def incoming_issues_for(options={})
    issues = incoming_issues
    if @fill_incoming && issues.length < @settings['panes']['incoming']['limit'].to_i
      limit = @settings['panes']['incoming']['limit'].to_i - issues.length
      issues += incoming_pane.get_issues(:user => nil,
                                         :for => nil,
                                         :exclude_ids => issues.collect(&:id),
                                         :limit => limit)
    end
    
    issues
  end


  # OPTIMIZE: could cache this to ivars
  def canceled_issues_for(options={})
    project = options[:project]

    # Organized by {assigned_user => [issues]}
    issues = canceled_issues.values.flatten.select {|issue|
      if roll_up_projects?
        issue.project_id == project.id || issue.project.is_descendant_of?(project)
      else
        issue.project == project
      end
    }
    issues ||= []
    issues
  end

  # OPTIMIZE: could cache this to ivars
  def finished_issues_for(options={})
    project = options[:project]

    # Organized by {assigned_user => [issues]}
    issues = finished_issues.values.flatten.select {|issue|
      if roll_up_projects?
        issue.project_id == project.id || issue.project.is_descendant_of?(project)
      else
        issue.project == project
      end
    }
    issues ||= []
    issues
  end

  def get_users
    if @user
      @users = [@user]
    else
      role_id = @settings["staff_role"].to_i
      if role_id
        query_conditions = ARCondition.new
        query_conditions.add ["#{MemberRole.table_name}.role_id = ?", role_id]
        query_conditions.add "#{MemberRole.table_name}.member_id = #{Member.table_name}.id"
        query_conditions.add "#{Member.table_name}.user_id = #{User.table_name}.id"
        @users = User.active.all(:conditions => query_conditions.conditions,
                          :select => "users.*",
                          :joins => "LEFT  JOIN members ON members.user_id = users.id LEFT  JOIN projects ON projects.id = members.project_id LEFT  JOIN member_roles ON (members.id = member_roles.member_id) LEFT  JOIN roles ON (roles.id = member_roles.role_id) LEFT  JOIN member_roles member_roles_members ON member_roles_members.member_id = members.id")
      end
      @users ||= []
      @users = move_current_user_to_front
      @users << UnknownUser.instance
      @users.uniq!
      @users
    end
  end

  # Find all of the projects referenced on the KanbanIssue and Issues
  def projects
    projects = Project.all(:conditions => Project.allowed_to_condition(User.current, :view_issues))
    # User isn't a member but they created an issue which was moved out of their visibility
    projects += Project.all(:include => :issues,
                            :conditions => ["#{Issue.table_name}.author_id = :user", {:user => User.current.id}])

    roll_up_projects_to_project_level(projects).uniq
  end

  def has_issues_for_project_and_user?(project, user)
    opts = {:user => user, :project => project}

    # TODO: should be refactored to use enum#any?
    return true if finished_issues_for(opts).length > 0
    return true if canceled_issues_for(opts).length > 0
    return true if testing_issues_for(opts).length > 0
    return true if active_issues_for(opts).length > 0
    return true if selected_issues_for(opts).length > 0
    return true if backlog_issues_for(opts).length > 0
    return false
  end
  
  def quick_issue_ids
    if quick_issues.present? && quick_issues.flatten.present?
      quick_issues.collect {|ary| ary[1] }.flatten.collect(&:id)
    else
      []
    end
  end

  def project_level
    unless @project_level
      @project_level = Setting.plugin_redmine_kanban['project_level'].to_i if Setting.plugin_redmine_kanban['project_level'].present?
      @project_level ||= 0
    end
    
    @project_level
  end

  def roll_up_projects?
    project_level > 0
  end

  # Updates the Issue with +issue_id+ to change it's
  # * Status to the IssueStatus set for the +to+ pane
  # * Assignment to the +target_user+ on staffed panes
  def self.update_issue_attributes(issue_id, from, to, user=User.current, target_user=nil, extra_attributes = {})
    @settings = Setting.plugin_redmine_kanban

    issue = Issue.find_by_id(issue_id)

    if @settings['panes'][to] && @settings['panes'][to]['status']
      new_status = IssueStatus.find_by_id(@settings['panes'][to]['status'].to_i)
    end
      
    if issue && new_status
      issue.init_journal(user)
      issue.attributes = extra_attributes if extra_attributes
      issue.status = new_status

      if Kanban.staffed_panes.include?(to) && !target_user.nil? && target_user.is_a?(User)
        issue.assigned_to = target_user
      end

      return issue.save
    else
      return false
    end

  end

  # Updates +target_pane+ so that the KanbanIssues match +sorted_issues+
  def self.update_sorted_issues(target_pane, sorted_issues, user_id=nil)
    if Kanban.kanban_issues_panes.include?(target_pane)
      if sorted_issues.blank? && !target_pane.blank?
        KanbanIssue.destroy_all(:state => target_pane, :user_id => user_id)
      else
        # Remove items that are in the database but not in the
        # sorted_issues
        if user_id
          KanbanIssue.destroy_all(['state = ? AND user_id = ? AND issue_id NOT IN (?)',target_pane, user_id, sorted_issues])
        else
          KanbanIssue.destroy_all(['state = ? AND issue_id NOT IN (?)',target_pane, sorted_issues])
        end
          
        sorted_issues.each_with_index do |issue_id, zero_position|
          kanban_issue = KanbanIssue.find_by_issue_id(issue_id)
          if kanban_issue
            if kanban_issue.state != target_pane
              # Change state
              kanban_issue.send(target_pane.to_sym)
            end
            kanban_issue.user_id = user_id unless target_pane == 'selected'
            kanban_issue.position = zero_position + 1 # acts_as_list is 1 based
            kanban_issue.save
          else
            kanban_issue = KanbanIssue.new({:issue_id => issue_id,
                                             :state => target_pane,
                                             :position => (zero_position + 1)})
            kanban_issue.user_id = user_id unless target_pane == 'selected'
            kanban_issue.save
            # Need to resave since acts_as_list automatically moves a
            # new issue to the bottom on create
            kanban_issue.insert_at(zero_position + 1)
          end
        end
      end
    end
  end

  private

  def move_current_user_to_front
    if user = @users.delete(User.current)
      @users.unshift(user)
    else
      @users
    end
  end

  # Returns a list of projects that are higher up in the tree than project_level
  #
  # Recursive
  def roll_up_projects_to_project_level(projects)
    return projects if project_level == 0
    
    projects.inject([]) {|filtered, project|
      if project.level >= project_level
        filtered + roll_up_projects_to_project_level(project.ancestors)
      else
        filtered << project
      end
      filtered.uniq
    }
  end

end
