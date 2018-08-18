# coding: utf-8
require 'shellwords'
require 'fileutils'
require 'credentials_manager/account_manager'

require_relative 'features'
require_relative 'helper'
require_relative 'fastlane_pty'

module FastlaneCore
  # The TransporterInputError occurs when you passed wrong inputs to the {Deliver::ItunesTransporter}
  class TransporterInputError < StandardError
  end
  # The TransporterTransferError occurs when some error happens
  # while uploading or downloading something from/to iTC
  class TransporterTransferError < StandardError
  end

  # Used internally
  class TransporterRequiresApplicationSpecificPasswordError < StandardError
  end

  # Base class for executing the iTMSTransporter
  class TransporterExecutor
    ERROR_REGEX = />\s*ERROR:\s+(.+)/
    WARNING_REGEX = />\s*WARN:\s+(.+)/
    OUTPUT_REGEX = />\s+(.+)/
    RETURN_VALUE_REGEX = />\sDBG-X:\sReturning\s+(\d+)/

    SKIP_ERRORS = ["ERROR: An exception has occurred: Scheduling automatic restart in 1 minute"]

    private_constant :ERROR_REGEX, :WARNING_REGEX, :OUTPUT_REGEX, :RETURN_VALUE_REGEX, :SKIP_ERRORS

    def execute(command, hide_output)
      if Helper.test?
        return {
          successful: command,
          output: nil
        }
      end

      # Workaround because the traditional transporter broke on 1st March 2018
      # More information https://github.com/fastlane/fastlane/issues/11958
      # As there was no communication from Apple, we don't know if this is a temporary
      # server outage, or something they changed without giving a heads-up
      if ENV["DELIVER_ITMSTRANSPORTER_ADDITIONAL_UPLOAD_PARAMETERS"].to_s.length == 0
        ENV["DELIVER_ITMSTRANSPORTER_ADDITIONAL_UPLOAD_PARAMETERS"] = "-t DAV"
      end

      @errors = []
      @warnings = []
      @all_lines = []

      if hide_output
        # Show a one time message instead
        UI.success("Waiting for App Store Connect transporter to be finished.")
        UI.success("iTunes Transporter progress... this might take a few minutes...")
      end

      begin
        FastlaneCore::FastlanePty.spawn(command) do |command_stdout, command_stdin, pid|
          begin
            command_stdout.each do |line|
              @all_lines << line
              parse_line(line, hide_output) # this is where the parsing happens
            end
          rescue Errno::EIO
            # Exception ignored intentionally.
            # https://stackoverflow.com/questions/10238298/ruby-on-linux-pty-goes-away-without-eof-raises-errnoeio
          ensure
            Process.wait(pid)
          end
        end
      rescue => ex
        @errors << ex.to_s
      end

      exit_status = $?.exitstatus
      unless exit_status.zero?
        @errors << "The call to the iTMSTransporter completed with a non-zero exit status: #{exit_status}. This indicates a failure."
      end

      if @warnings.count > 0
        UI.important(@warnings.join("\n"))
      end

      if @errors.join("").include?("app-specific")
        raise TransporterRequiresApplicationSpecificPasswordError
      end

      if @errors.count > 0 && @all_lines.count > 0
        # Print out the last 15 lines, this is key for non-verbose mode
        @all_lines.last(15).each do |line|
          UI.important("[iTMSTransporter] #{line}")
        end
        UI.message("iTunes Transporter output above ^")
        UI.error(@errors.join("\n"))
      end

      # this is to handle GitHub issue #1896, which occurs when an
      #  iTMSTransporter file transfer fails; iTMSTransporter will log an error
      #  but will then retry; if that retry is successful, we will see the error
      #  logged, but since the status code is zero, we want to return success
      if @errors.count > 0 && exit_status.zero?
        UI.important("Although errors occurred during execution of iTMSTransporter, it returned success status.")
      end

      {
        successful: exit_status.zero?,
        output: @all_lines
      }
    end

    private

    def parse_line(line, hide_output)
      # Taken from https://github.com/sshaw/itunes_store_transporter/blob/master/lib/itunes/store/transporter/output_parser.rb

      output_done = false

      re = Regexp.union(SKIP_ERRORS)
      if line.match(re)
        # Those lines will not be handled like errors or warnings

      elsif line =~ ERROR_REGEX
        @errors << $1
        UI.error("[Transporter Error Output]: #{$1}")

        # Check if it's a login error
        if $1.include?("Your Apple ID or password was entered incorrectly") ||
           $1.include?("This Apple ID has been locked for security reasons")

          unless Helper.test?
            CredentialsManager::AccountManager.new(user: @user).invalid_credentials
            UI.error("Please run this tool again to apply the new password")
          end
        elsif $1.include?("Redundant Binary Upload. There already exists a binary upload with build")
          UI.error($1)
          UI.error("You have to change the build number of your app to upload your ipa file")
        end

        output_done = true
      elsif line =~ WARNING_REGEX
        @warnings << $1
        UI.important("[Transporter Warning Output]: #{$1}")
        output_done = true
      end

      if line =~ RETURN_VALUE_REGEX
        if $1.to_i != 0
          UI.error("Transporter transfer failed.")
          UI.important(@warnings.join("\n"))
          UI.error(@errors.join("\n"))
          UI.crash!("Return status of iTunes Transporter was #{$1}: #{@errors.join('\n')}")
        else
          UI.success("iTunes Transporter successfully finished its job")
        end
      end

      if !hide_output && line =~ OUTPUT_REGEX
        # General logging for debug purposes
        unless output_done
          UI.verbose("[Transporter]: #{$1}")
        end
      end
    end
  end

  # Generates commands and executes the iTMSTransporter through the shell script it provides by the same name
  class ShellScriptTransporterExecutor < TransporterExecutor
    def build_upload_command(username, password, source = "/tmp", provider_short_name = "")
      [
        '"' + Helper.transporter_path + '"',
        "-m upload",
        "-u \"#{username}\"",
        "-p #{shell_escaped_password(password)}",
        "-f '#{source}'",
        ENV["DELIVER_ITMSTRANSPORTER_ADDITIONAL_UPLOAD_PARAMETERS"], # that's here, because the user might overwrite the -t option
        "-t 'Signiant'",
        "-k 100000",
        ("-itc_provider #{provider_short_name}" unless provider_short_name.to_s.empty?)
      ].compact.join(' ')
    end

    def build_download_command(username, password, apple_id, destination = "/tmp", provider_short_name = "")
      [
        '"' + Helper.transporter_path + '"',
        "-m lookupMetadata",
        "-u \"#{username}\"",
        "-p #{shell_escaped_password(password)}",
        "-apple_id #{apple_id}",
        "-destination '#{destination}'",
        ("-itc_provider #{provider_short_name}" unless provider_short_name.to_s.empty?)
      ].compact.join(' ')
    end

    def build_provider_ids_command(username, password)
      [
        '"' + Helper.transporter_path + '"',
        '-m provider',
        "-u \"#{username}\"",
        "-p #{shell_escaped_password(password)}"
      ].compact.join(' ')
    end

    def handle_error(password)
      # rubocop:disable Style/CaseEquality
      unless password === /^[0-9a-zA-Z\.\$\_]*$/
        UI.error([
          "Password contains special characters, which may not be handled properly by iTMSTransporter.",
          "If you experience problems uploading to App Store Connect, please consider changing your password to something with only alphanumeric characters."
        ].join(' '))
      end
      # rubocop:enable Style/CaseEquality
      UI.error("Could not download/upload from App Store Connect! It's probably related to your password or your internet connection.")
    end

    private

    def shell_escaped_password(password)
      # because the shell handles passwords with single-quotes incorrectly, use gsub to replace ShellEscape'd single-quotes of this form:
      #    \'
      # with a sequence that wraps the escaped single-quote in double-quotes:
      #    '"\'"'
      # this allows us to properly handle passwords with single-quotes in them
      # we use the 'do' version of gsub, because two-param version interprets the replace text as a pattern and does the wrong thing
      password = Shellwords.escape(password).gsub("\\'") do
        "'\"\\'\"'"
      end

      # wrap the fully-escaped password in single quotes, since the transporter expects a escaped password string (which must be single-quoted for the shell's benefit)
      "'" + password + "'"
    end
  end

  # Generates commands and executes the iTMSTransporter by invoking its Java app directly, to avoid the crazy parameter
  # escaping problems in its accompanying shell script.
  class JavaTransporterExecutor < TransporterExecutor
    def build_upload_command(username, password, source = "/tmp", provider_short_name = "")
      [
        Helper.transporter_java_executable_path.shellescape,
        "-Djava.ext.dirs=#{Helper.transporter_java_ext_dir.shellescape}",
        '-XX:NewSize=2m',
        '-Xms32m',
        '-Xmx1024m',
        '-Xms1024m',
        '-Djava.awt.headless=true',
        '-Dsun.net.http.retryPost=false',
        java_code_option,
        '-m upload',
        "-u #{username.shellescape}",
        "-p #{password.shellescape}",
        "-f #{source.shellescape}",
        ENV["DELIVER_ITMSTRANSPORTER_ADDITIONAL_UPLOAD_PARAMETERS"], # that's here, because the user might overwrite the -t option
        '-t Signiant',
        '-k 100000',
        ("-itc_provider #{provider_short_name}" unless provider_short_name.to_s.empty?),
        '2>&1' # cause stderr to be written to stdout
      ].compact.join(' ') # compact gets rid of the possibly nil ENV value
    end

    def build_download_command(username, password, apple_id, destination = "/tmp", provider_short_name = "")
      [
        Helper.transporter_java_executable_path.shellescape,
        "-Djava.ext.dirs=#{Helper.transporter_java_ext_dir.shellescape}",
        '-XX:NewSize=2m',
        '-Xms32m',
        '-Xmx1024m',
        '-Xms1024m',
        '-Djava.awt.headless=true',
        '-Dsun.net.http.retryPost=false',
        java_code_option,
        '-m lookupMetadata',
        "-u #{username.shellescape}",
        "-p #{password.shellescape}",
        "-apple_id #{apple_id.shellescape}",
        "-destination #{destination.shellescape}",
        ("-itc_provider #{provider_short_name}" unless provider_short_name.to_s.empty?),
        '2>&1' # cause stderr to be written to stdout
      ].compact.join(' ')
    end

    def build_provider_ids_command(username, password)
      [
        Helper.transporter_java_executable_path.shellescape,
        "-Djava.ext.dirs=#{Helper.transporter_java_ext_dir.shellescape}",
        '-XX:NewSize=2m',
        '-Xms32m',
        '-Xmx1024m',
        '-Xms1024m',
        '-Djava.awt.headless=true',
        '-Dsun.net.http.retryPost=false',
        java_code_option,
        '-m provider',
        "-u #{username.shellescape}",
        "-p #{password.shellescape}",
        '2>&1' # cause stderr to be written to stdout
      ].compact.join(' ')
    end

    def java_code_option
      if Helper.mac? && Helper.xcode_at_least?(9)
        return "-jar #{Helper.transporter_java_jar_path.shellescape}"
      else
        return "-classpath #{Helper.transporter_java_jar_path.shellescape} com.apple.transporter.Application"
      end
    end

    def handle_error(password)
      unless File.exist?(Helper.transporter_java_jar_path)
        UI.error("The iTMSTransporter Java app was not found at '#{Helper.transporter_java_jar_path}'.")
        UI.error("If you're using Xcode 6, please select the shell script executor by setting the environment variable "\
          "FASTLANE_ITUNES_TRANSPORTER_USE_SHELL_SCRIPT=1")
      end
    end

    def execute(command, hide_output)
      # The Java command needs to be run starting in a working directory in the iTMSTransporter
      # file area. The shell script takes care of changing directories over to there, but we'll
      # handle it manually here for this strategy.
      FileUtils.cd(Helper.itms_path) do
        return super(command, hide_output)
      end
    end
  end

  class ItunesTransporter
    PROVIDER_REGEX = /^\d+\s{2,}.+\s{2,}[^\s]+$/
    TWO_STEP_HOST_PREFIX = "deliver.appspecific"

    # This will be called from the Deliverfile, and disables the logging of the transporter output
    def self.hide_transporter_output
      @hide_transporter_output = !FastlaneCore::Globals.verbose?
    end

    def self.hide_transporter_output?
      @hide_transporter_output
    end

    # Returns a new instance of the iTunesTransporter.
    # If no username or password given, it will be taken from
    # the #{CredentialsManager::AccountManager}
    # @param use_shell_script if true, forces use of the iTMSTransporter shell script.
    #                         if false, allows a direct call to the iTMSTransporter Java app (preferred).
    #                         see: https://github.com/fastlane/fastlane/pull/4003
    # @param provider_short_name The provider short name to be given to the iTMSTransporter to identify the
    #                            correct team for this work. The provider short name is usually your Developer
    #                            Portal team ID, but in certain cases it is different!
    #                            see: https://github.com/fastlane/fastlane/issues/1524#issuecomment-196370628
    #                            for more information about how to use the iTMSTransporter to list your provider
    #                            short names
    def initialize(user = nil, password = nil, use_shell_script = false, provider_short_name = nil)
      # Xcode 6.x doesn't have the same iTMSTransporter Java setup as later Xcode versions, so
      # we can't default to using the better direct Java invocation strategy for those versions.
      use_shell_script ||= Helper.xcode_version.start_with?('6.')
      use_shell_script ||= Feature.enabled?('FASTLANE_ITUNES_TRANSPORTER_USE_SHELL_SCRIPT')

      @user = user
      @password = password || load_password_for_transporter

      @transporter_executor = use_shell_script ? ShellScriptTransporterExecutor.new : JavaTransporterExecutor.new
      @provider_short_name = provider_short_name
    end

    # Downloads the latest version of the app metadata package from iTC.
    # @param app_id [Integer] The unique App ID
    # @param dir [String] the path in which the package file should be stored
    # @return (Bool) True if everything worked fine
    # @raise [Deliver::TransporterTransferError] when something went wrong
    #   when transferring
    def download(app_id, dir = nil)
      dir ||= "/tmp"

      UI.message("Going to download app metadata from App Store Connect")
      command = @transporter_executor.build_download_command(@user, @password, app_id, dir, @provider_short_name)
      UI.verbose(@transporter_executor.build_download_command(@user, 'YourPassword', app_id, dir, @provider_short_name))

      begin
        result = @transporter_executor.execute(command, ItunesTransporter.hide_transporter_output?)[:successful]
      rescue TransporterRequiresApplicationSpecificPasswordError => ex
        handle_two_step_failure(ex)
        return download(app_id, dir)
      end

      return result if Helper.test?

      itmsp_path = File.join(dir, "#{app_id}.itmsp")
      successful = result && File.directory?(itmsp_path)

      if successful
        UI.success("✅ Successfully downloaded the latest package from App Store Connect to #{itmsp_path}")
      else
        handle_error(@password)
      end

      successful
    end

    # Uploads the modified package back to App Store Connect
    # @param app_id [Integer] The unique App ID
    # @param dir [String] the path in which the package file is located
    # @return (Bool) True if everything worked fine
    # @raise [Deliver::TransporterTransferError] when something went wrong
    #   when transferring
    def upload(app_id, dir)
      actual_dir = File.join(dir, "#{app_id}.itmsp")

      UI.message("Going to upload updated app to App Store Connect")
      UI.success("This might take a few minutes. Please don't interrupt the script.")

      command = @transporter_executor.build_upload_command(@user, @password, actual_dir, @provider_short_name)
      UI.verbose(@transporter_executor.build_upload_command(@user, 'YourPassword', actual_dir, @provider_short_name))

      begin
        result = @transporter_executor.execute(command, ItunesTransporter.hide_transporter_output?)[:successful]
      rescue TransporterRequiresApplicationSpecificPasswordError => ex
        handle_two_step_failure(ex)
        return upload(app_id, dir)
      end

      if result
        UI.header("Successfully uploaded package to App Store Connect. It might take a few minutes until it's visible online.")

        FileUtils.rm_rf(actual_dir) unless Helper.test? # we don't need the package any more, since the upload was successful
      else
        handle_error(@password)
      end

      result
    end

    def provider_ids
      command = @transporter_executor.build_provider_ids_command(@user, @password)
      UI.verbose(@transporter_executor.build_provider_ids_command(@user, 'YourPassword'))
      begin
        result = @transporter_executor.execute(command, ItunesTransporter.hide_transporter_output?)[:output]
      rescue TransporterRequiresApplicationSpecificPasswordError => ex
        handle_two_step_failure(ex)
        return provider_ids
      end

      result.map { |line| provider_pair(line) }.compact.to_h
    end

    private

    TWO_FACTOR_ENV_VARIABLE = "FASTLANE_APPLE_APPLICATION_SPECIFIC_PASSWORD"

    # Returns the password to be used with the transporter
    def load_password_for_transporter
      # 3 different sources for the password
      #   1) ENV variable for application specific password
      if ENV[TWO_FACTOR_ENV_VARIABLE].to_s.length > 0
        UI.message("Fetching password for transporter from environment variable named `#{TWO_FACTOR_ENV_VARIABLE}`")
        return ENV[TWO_FACTOR_ENV_VARIABLE]
      end
      #   2) TWO_STEP_HOST_PREFIX from keychain
      account_manager = CredentialsManager::AccountManager.new(user: @user,
                                                             prefix: TWO_STEP_HOST_PREFIX,
                                                               note: "application-specific")
      password = account_manager.password(ask_if_missing: false)
      return password if password.to_s.length > 0
      #   3) standard iTC password
      account_manager = CredentialsManager::AccountManager.new(user: @user)
      return account_manager.password(ask_if_missing: true)
    end

    # Tells the user how to get an application specific password
    def handle_two_step_failure(ex)
      if ENV[TWO_FACTOR_ENV_VARIABLE].to_s.length > 0
        # Password provided, however we already used it
        UI.error("Application specific password you provided using #{TWO_FACTOR_ENV_VARIABLE}")
        UI.error("is invalid, please make sure it's correct")
        UI.user_error!("Invalid application specific password provided")
      end

      a = CredentialsManager::AccountManager.new(user: @user,
                                               prefix: TWO_STEP_HOST_PREFIX,
                                                 note: "application-specific")
      if a.password(ask_if_missing: false).to_s.length > 0
        # user already entered one.. delete the old one
        UI.error("Application specific password seems wrong")
        UI.error("Please make sure to follow the instructions")
        a.remove_from_keychain
      end
      UI.error("Your account has 2 step verification enabled")
      UI.error("Please go to https://appleid.apple.com/account/manage")
      UI.error("and generate an application specific password for")
      UI.error("the iTunes Transporter, which is used to upload builds")
      UI.error("To set the application specific password on a CI machine using")
      UI.error("an environment variable, you can set the")
      UI.error("#{TWO_FACTOR_ENV_VARIABLE} variable")
      @password = a.password(ask_if_missing: true) # to ask the user for the missing value

      return true
    end

    def handle_error(password)
      @transporter_executor.handle_error(password)
    end

    def provider_pair(line)
      line = line.strip
      return nil unless line =~ PROVIDER_REGEX
      line.split(/\s{2,}/).drop(1)
    end
  end
end
