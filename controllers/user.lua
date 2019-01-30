-- User API controller
-- ===================
--
-- Written by Bernat Romagosa and Michael Ball
--
-- Copyright (C) 2019 by Bernat Romagosa and Michael Ball
--
-- This file is part of Snap Cloud.
--
-- Snap Cloud is free software: you can redistribute it and/or modify
-- it under the terms of the GNU Affero General Public License as
-- published by the Free Software Foundation, either version 3 of
-- the License, or (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU Affero General Public License for more details.
--
-- You should have received a copy of the GNU Affero General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

local util = package.loaded.util
local validate = package.loaded.validate
local db = package.loaded.db
local cached = package.loaded.cached
local yield_error = package.loaded.yield_error

local Users = package.loaded.Users
local DeletedUsers = package.loaded.DeletedUsers
local Projects = package.loaded.Projects
local Tokens = package.loaded.Tokens

require 'responses'
require 'validation'
require 'passwords'

UserController = {
    GET = {
        current_user = function (self)
            -- GET /users/c
            -- Description: Get the currently logged user's username and credentials.
            if self.current_user then
                self.session.verified = self.current_user.verified
                self.session.user_id = self.current_user.id
            elseif self.session.username == '' then
                self.session.role = nil
                self.session.verified = false
                self.session.user_id = nil
            end

            return jsonResponse({
                username = self.session.username,
                role = self.session.role,
                verified = self.session.verified,
                id = self.session.user_id
            })
        end,

        user_list = function (self)
            -- GET /users
            -- Description: Get a paginated list of all users with username or email matching
            --              matchtext, if provided. Returned parameters will depend on query
            --              issuer permissions.
            -- Parameters:  matchtext, page, pagesize

            assert_logged_in(self)
            if not self.params.matchtext then assert_has_one_of_roles(self, { 'admin', 'moderator' }) end

            local paginator

            if self.current_user:has_one_of_roles({ 'admin', 'moderator' }) then
                paginator = Users:paginated(
                    self.params.matchtext and
                        db.interpolate_query(
                            'where username ILIKE ? or email ILIKE ?',
                            self.params.matchtext,
                            self.params.matchtext
                        )
                        or 'order by verified, created',
                    {
                        per_page = self.params.pagesize or 16,
                        fields = 'username, id, created, email, verified, role'
                    }
                )
            else
                paginator = Users:paginated(
                    db.interpolate_query('where username ILIKE ?', self.params.matchtext),
                    {
                        per_page = self.params.pagesize or 16,
                        fields = 'username'
                    }
                )
            end

            return jsonResponse({
                pages = self.params.page and paginator:num_pages() or nil,
                users = self.params.page and paginator:get_page(self.params.page) or paginator:get_all()
            })
        end,

        with_email = function (self)
            -- GET /users/email/:email
            -- Description: Sends an email to :email with all users associated with said :email
            local users = assert_users_have_email(self)
            local body = '<ul>'

            for _, user in pairs(users) do
                body = body .. '<li>' .. user.username .. '</li>'
            end

            body = body .. '</ul>'

            send_mail(
                self.params.email,
                mail_subjects.users_for_email,
                mail_bodies.users_for_email .. body)
        end,

        user = function (self)
            -- GET /users/:username
            -- Description: Get info about a user
            if not users_match(self) then assert_admin(self) end
            return jsonResponse(
                Users:select(
                    'where username = ? limit 1',
                    self.params.username,
                    { fields = 'username, created, role, email, verified, id' })[1])
        end,

        password_reset = function (self)
            -- GET /users/:username/password_reset(/:token)
            -- Description: Check whether a reset password token is correct, and reset
            --              a user's password if so.
            return check_token(
                self.params.token,
                'password_reset',
                function (user)
                    local password, prehash = random_password()
                    user:update({ password = hash_password(prehash, user.salt) })
                    send_mail(
                        user.email,
                        mail_subjects.new_password .. user.username,
                        mail_bodies.new_password .. '<p><h2>' .. password .. '</h2></p>')

                    return htmlPage(
                        'Password reset',
                        '<p>A new random password has been generated for your account <strong>' .. user.username .. '</strong> and sent to your email address. Please check your inbox.</p>' ..
                        '<p>After logging in, please proceed to <strong>change your password</strong> as soon as possible.</p>'
                    )
                end
            )
        end,

        verify_user = function (self)
            -- GET /users/:username/verify_user/:token
            -- Description: Verifies a user's email by means of a token, or removes
            --              that token if it has expired.
            --              If requesting user is an admin, verifies the user and removes
            --              the token. Token should equal '0' for admins.
            --              Returns a success message if the user is already verified.
            --              The route name should match the database token purpose.
            local user_page = function (user)
                return htmlPage(
                    'User verified | Welcome to Snap<em>!</em>',
                    '<p>Your account <strong>' .. user.username .. '</strong> has been verified.</p>' ..
                    '<p>Thank you!</p>' ..
                    '<p><a href="https://snap.berkeley.edu/run">Take me to Snap<i>!</i></a></p>'
                )
            end
            assert_user_exists(self)
            if self.queried_user.verified then
                return user_page(self.queried_user)
            end

            -- admins can verify people without the need of a token
            if self.params.token == '0' then assert_admin(self)
                local token = Tokens:select('where username = ? and purpose = ?', self.queried_user.username, 'verify_user')
                if (token and token[1]) then token[1]:delete() end
                self.queried_user:update({ verified = true })
                return okResponse('User ' .. self.queried_user.username .. ' has been verified')
            end

            return check_token(
                self.params.token,
                'verify_user',
                function (user)
                    -- success callback
                    user:update({ verified = true })
                    self.session.verified = true
                    return user_page(user)
                end
            )
        end
    },

    POST = {
        user = function (self)
            -- POST /users/:username
            -- Description: Add or update a user. All passwords should travel pre-hashed with SHA512.
            -- Parameters:  username, password, password_repeat, email, role
            if (self.current_user) then
                -- user is updating profile, or an admin is updating somebody else's profile
                if not users_match(self) then
                    if self.params.role then
                        assert_can_set_role(self, self.params.role)
                    else
                        assert_admin(self)
                    end
                end
                self.queried_user:update({
                    email = self.params.email or self.queried_user.email,
                    role = self.params.role or self.queried_user.role
                })
                if (self.params.role == 'banned') then
                    -- We need to unlist all projects by this user
                    db.update('projects', { ispublished = false }, { username = self.queried_user.username })
                end
                if self.params.role then
                    send_mail(
                        self.queried_user.email,
                        mail_subjects['set_role_' .. self.params.role] .. self.queried_user.username,
                        mail_bodies['set_role_' .. self.params.role])
                end
                return okResponse('Profile for user ' .. self.queried_user.username .. ' updated')
            else
                -- new user
                validate.assert_valid(self.params, {
                    { 'username', exists = true, min_length = 4, max_length = 200 },
                    { 'password', exists = true, min_length = 6 },
                    { 'password_repeat', equals = self.params.password, 'passwords do not match' },
                    { 'email', exists = true, min_length = 5 },
                })

                if self.queried_user then
                    yield_error('User ' .. self.queried_user.username .. ' already exists');
                end

                local salt = secure_salt()
                Users:create({
                    created = db.format_date(),
                    username = self.params.username,
                    salt = salt,
                    password = hash_password(self.params.password, salt), -- see validation.lua >> hash_password
                    email = self.params.email,
                    verified = false,
                    role = 'standard'
                })

                -- Create a verify_user-type token and send an email to the user asking to
                -- verify the account.
                -- We check these on login.
                create_token(self, 'verify_user', self.params.username, self.params.email)
                return okResponse(
                'User ' .. self.params.username ..
                ' created.\nPlease check your email and validate your\naccount within the next 3 days.')
            end
        end,

        new_password = function (self)
            -- POST /users/:username/newpassword
            -- Description: Sets a new password for a user. All passwords should travel pre-hashed
            --              with SHA512.
            -- Parameters:  oldpassword, password_repeat, newpassword
            assert_all({'user_exists', 'users_match'}, self)

            if self.queried_user.password ~= hash_password(self.params.oldpassword, self.queried_user.salt) then
                yield_error('wrong password')
            end

            validate.assert_valid(self.params, {
                { 'password_repeat', equals = self.params.newpassword, 'passwords do not match' },
                { 'newpassword', exists = true, min_length = 6 }
            })

            self.queried_user:update({
                password = hash_password(self.params.newpassword, self.queried_user.salt)
            })

            return okResponse('Password updated')
        end,

        resend_verification = function (self)
            -- POST /users/:username/resendverification
            -- Description: Resends user verification email.
            assert_user_exists(self)
            if self.queried_user.verified then
                return okResponse(
                    'User ' .. self.queried_user.username ..
                    ' is already verified.\nThere is no need for you to do anything.\n')
            end
            create_token(self, 'verify_user', self.queried_user.username, self.queried_user.email)
            return okResponse(
                'Verification email for ' .. self.queried_user.username ..
                ' sent.\nPlease check your email and validate your\n' ..
                'account within the next 3 days.')
        end,

        password_reset = function (self)
            -- POST /users/:username/password_reset(/:token)
            -- Description: Generate a token to reset a user's password.
            -- @see validation.create_token
            assert_user_exists(self)
            create_token(self, 'password_reset', self.params.username, self.queried_user.email)
            return okResponse('Password reset request sent.\nPlease check your email.')
        end,

        login = function (self)
            -- POST /users/:username/login
            -- Description: Logs a user into the system.
            -- Body:        password
            assert_user_exists(self)

            ngx.req.read_body()
            local password = ngx.req.get_body_data()

            if (hash_password(password, self.queried_user.salt) == self.queried_user.password) then
                if not self.queried_user.verified then
                    -- Check whether verification token is still unused and valid
                    local token =
                        Tokens:find({
                            username = self.queried_user.username,
                            purpose = 'verify_user'
                        })
                    if token then
                        local query = db.select("date_part('day', now() - ?::timestamp)", token.created)[1]
                        if query.date_part > 3 then
                            token:delete()
                            yield_error(err.nonvalidated_user)
                        else
                            self.queried_user.days_left = 3 - query.date_part
                        end
                    else
                        yield_error(err.nonvalidated_user)
                    end
                end
                self.session.username = self.queried_user.username
                self.session.role = self.queried_user.role
                self.session.verified = self.queried_user.verified
                self.session.user_id = self.queried_user.id
                self.cookies.persist_session = self.params.persist
                if self.queried_user.verified then
                    return okResponse('User ' .. self.queried_user.username .. ' logged in')
                else
                    return jsonResponse({ days_left = self.queried_user.days_left })
                end
            else
                -- Admins can log in as other people
                assert_admin(self, 'wrong password')
                local previous_username = self.current_user.username
                self.session.username = self.queried_user.username
                self.session.role = self.queried_user.role
                self.session.verified = self.queried_user.verified
                self.session.user_id = self.queried_user.id
                self.cookies.persist_session = 'false'
                return okResponse('User ' .. previous_username .. ' now logged in as ' .. self.queried_user.username)
            end
        end,

        logout = function (self)
            -- POST /logout
            -- Description: Logs out the current user from the system.
            self.session.username = ''
            self.session.user_id = nil
            self.cookies.persist_session = 'false'
            return okResponse('logged out')
        end,

        send_message = function (self)
            -- POST /users/:username/message
            -- Description: If requesting user has permissions to do so, send an email
            --              to queried user.
            -- Body:        subject, contents

            assert_admin(self)

            -- Read request body and parse it into JSON
            ngx.req.read_body()
            local body_data = ngx.req.get_body_data()
            local body = body_data and util.from_json(body_data) or nil

            if body and body.contents then
                send_mail(
                    self.queried_user.email,
                    body.subject or mail_subjects.generic,
                    body.contents
                )
                return okResponse('Message sent to user ' .. self.queried_user.username)
            else
                yield_error(err.mail_body_empty)
            end
        end
    },

    DELETE = {
        user = function (self)
            -- DELETE /users/:username
            -- Description: Delete a user.
            assert_user_exists(self)

            if not users_match(self) then assert_admin(self) end

            -- Do not actually delete the user; flag it as deleted.
            if not (self.queried_user:update({ deleted = db.format_date() })) then
                yield_error('Could not delete user ' .. self.params.username)
            else
                return okResponse('User ' .. self.params.username .. ' has been removed.')
            end
        end
    }
}
