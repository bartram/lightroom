-- Lightroom SDK
local LrView = import 'LrView'
local LrPathUtils = import 'LrPathUtils'
local LrDialogs = import 'LrDialogs'
local LrErrors = import 'LrErrors'
local LrHttp = import 'LrHttp'

local LrLogger = import 'LrLogger'

JSON = (loadfile(LrPathUtils.child(_PLUGIN.path, "JSON.lua")))() -- one-time load of the routines

local logger = LrLogger( 'console' )
logger:enable( "print" ) -- or "logfile"

local headers = {
  { field = 'Content-Type', value = 'application/json' },
  { field = 'Accept', value = 'application/json' },
}

local DrupalPublish = {
  supportsIncrementalPublish = 'only',
  supportsCustomSortOrder = true,
  exportPresetFields = {
    { key = 'url', default = '' },
    { key = 'username', default = '' },
    { key = 'password', default = '' },
  },
  showSections = {
    'imageSettings'
  },
  allowFileFormats = { 'JPEG' }
  --  small_icon = 'icon.small.png',
}

DrupalPublish.getUserToken = function ( props )

  local body, response = LrHttp.get( props.url .. 'services/session/token', headers)

  if (response.status == 200) then
    headers = {
      { field = 'Content-Type', value = 'application/json' },
      { field = 'Accept', value = 'application/json' },
      { field = 'X-CSRF-Token', value = body },
    }
    return body
  end

end

DrupalPublish.userLogin = function (props)

  -- @todo consider reusing user and userLogin

  -- User login
  local data = {
    username = props.username,
    password = props.password
  }
  local body, response = LrHttp.post( props.url .. 'lightroom/user/login', JSON.encode(data), {
    { field = 'Content-Type', value = 'application/json' },
    { field = 'Accept', value = 'application/json' },
    -- Clear cookies, so that we start a new session
    { field = 'Cookie', value = '' },
  })
  local data = JSON.decode(body)

  if not (response.status == 200) then
    user = nil
    if data then
      local message = table.concat(data, '\n')
      LrErrors.throwUserError( message )
    else
      LrErrors.throwUserError( 'User login failed. Please check the URL, user name, and password in the Publish Settings dialog, and confirm that Services are properly configured on your web site.' )
    end
  end

  if not (data.user) then
    LrErrors.throwUserError( 'Unable to load user.' )
  end

  -- Set user
  local user = data.user

  -- Get CSRF token
  local userToken = DrupalPublish.getUserToken( props )

  if not userToken then
    LrErrors.throwUserError( 'Unable to get user token.' )
  end

  return user, userToken

end

DrupalPublish.loadNode = function (props, nid)

  local body, response = LrHttp.get( props.url .. 'lightroom/node/' .. nid, headers )
  local node = JSON.decode(body)
  return node

end

DrupalPublish.saveNode = function (props, node)

  if node.nid then
      -- Update node
    local body, response = LrHttp.post(props.url .. 'lightroom/node/' .. node.nid, JSON.encode(node), headers, 'PUT')

    if not (response.status == 200) then
      LrErrors.throwUserError( 'Unable to update collection.' )
    end

  else
      -- Create node
    local body, response = LrHttp.post(props.url .. 'lightroom/node', JSON.encode(node), headers)

    if not (response.status == 200) then
      LrErrors.throwUserError( 'Unable to create collection.' )
    end

    node = JSON.decode(body)

  end

  return node

end

DrupalPublish.getCollectionBehaviorInfo = function ( publishSettings )

	return {
		defaultCollectionName = "New Collection",
		defaultCollectionCanBeDeleted = true,
		canAddCollection = true,
		maxCollectionSetDepth = 0,
		  -- Disable collection sets
	}

end

DrupalPublish.getCommentsFromPublishedCollection = function ( publishSettings, arrayOfPhotoInfo, commentCallback )
end

DrupalPublish.getCommentsFromPublishedCollection = function ( publishSettings, arrayOfPhotoInfo, commentCallback )
end

DrupalPublish.getRatingsFromPublishedCollection = function ( publishSettings, arrayOfPhotoInfo, ratingCallback )
end

DrupalPublish.startDialog = function( props )
end

DrupalPublish.endDialog = function( props, why )
  -- @todo validate user info here
end

DrupalPublish.sectionsForBottomOfDialog = function( viewFactory, propertyTable )

  local share = LrView.share
  local bind = LrView.bind
	local result = {

		{
			title = 'Drupal Settings',
			synopsis = bind { key = 'url', object = propertyTable },

			viewFactory:row {
				viewFactory:static_text {
					title = 'URL',
					alignment = 'right',
					width = share 'labelWidth'
				},

				viewFactory:edit_field {
				  value = bind 'url',
					fill_horizontal = 1,
			    immediate = true,
				}

			},
			viewFactory:row {
			  viewFactory:static_text {
			    title = 'User Name',
			    alignment = 'right',
			    width = share 'labelWidth',
			  },
			  viewFactory:edit_field {
			    value = bind 'username',
			    immediate = true,
			  },
			},
			viewFactory:row {
			  viewFactory:static_text {
			    title = 'Password',
			    alignment = 'right',
			    width = share 'labelWidth',
			  },
			  viewFactory:password_field {
			    value = bind 'password',
			    immediate = true,
			  },
			},
		},
	}

	return result

end
DrupalPublish.processRenderedPhotos = function( functionContext, exportContext )

	local props = exportContext.propertyTable

	-- Make a local reference to the export parameters.

	local exportSession = exportContext.exportSession

	-- Set progress title.
	local numPhotos = exportSession:countRenditions()
	local progressScope = exportContext:configureProgress {
		title = numPhotos > 1 and string.format("Publishing %d photos.", numPhotos) or "Publishing 1 photo."
	}

  -- Get collection info
  local publishedCollectionInfo = exportContext.publishedCollectionInfo

  -- User login
  local user, userToken = DrupalPublish.userLogin(props)

  local progressScope = exportContext:configureProgress {
		title = "Uploading",
	}

  local node
  local images = {}

  if publishedCollectionInfo.remoteId then

    node = DrupalPublish.loadNode(props, publishedCollectionInfo.remoteId)

    -- Strip out everything but the fid for the field items
    -- Drupal will throw SQL exceptions if we try to save width/height, etc.
    -- Use a table so that we can easily replace values
    if node.field_collection_images and node.field_collection_images.und then
      for delta, item in pairs(node.field_collection_images.und) do
        images[item.fid] = { fid = item.fid }
      end
    end

    -- Just use the basic fields, so we don't overwrite anything
    node = {
      nid = node.nid,
		  type = 'collection',
      title = publishedCollectionInfo.name,
      field_collection_images = { und = {} },
    }

  else

		node = {
		  uid = user.uid,
		  type = 'collection',
		  title = publishedCollectionInfo.name,
		  field_collection_images = { und = {} },
		}

  end

	for i, rendition in exportContext:renditions{ stopIfCanceled = true } do

		-- Wait for next photo to render.
		local success, filePath = rendition:waitForRender()

		-- Check for cancellation again after photo has been rendered.
		if progressScope:isCanceled() then
		  return
		end

		if success then

			local fileName = LrPathUtils.leafName( filePath )

			-- Upload the new file
      local body, response = LrHttp.postMultipart( props.url .. 'lightroom/file/create_raw',
        {
          {
            name = 'files[]',
            fileName = fileName,
            filePath = filePath,
            contentType = 'application/octet-stream'
          }
        },
        {
          { field = 'Accept', value = 'application/json' },
          { field = 'X-CSRF-Token', value = userToken },
        }
      )

      -- Handle errors
      if not (response.status == 200) then
        -- log the error
        -- continue or cancel?
        LrErrors.throwUserError( 'Unable to upload file.' )

      end

      local file = JSON.decode(body)
      local fid = file[1].fid

		  if rendition.publishedPhotoId then
		    -- Replace existing fid with the new fid
		    images[rendition.publishedPhotoId] = {
		      fid = fid
		    }
		  else
		    -- Insert a new file
		    images[fid] = {
		      fid = fid
		    }
      end

      -- Set the remote ID for this rendition
			rendition:recordPublishedPhotoId( fid )

		end

  end

  -- Map images table to field array
  for key, value in pairs(images) do
  	table.insert(node.field_collection_images.und, value)
  end

  -- Create presentation
  node = DrupalPublish.saveNode( props, node )
	exportSession:recordRemoteCollectionId( node.nid )

end

DrupalPublish.imposeSortOrderOnPublishedCollection = function( props, info, remoteIdSequence )

  if info.remoteCollectionId then

    DrupalPublish.userLogin(props)

    local node = DrupalPublish.loadNode(props, info.remoteCollectionId)
    -- Reset the field
    node = {
      nid = node.nid,
      field_collection_images = { und = {} }
    }

    -- Update the order of images
    for i, fid in pairs(remoteIdSequence) do
    	table.insert(node.field_collection_images.und, { fid = fid })
    end

    -- Save node
    DrupalPublish.saveNode(props, node)

  end

end

DrupalPublish.renamePublishedCollection = function( props, info )

	if info.remoteId then

    DrupalPublish.userLogin(props)

    local node = DrupalPublish.loadNode(props, info.remoteId)
    -- Update the node title
    node = {
      nid = node.nid,
      title = info.name,
    }

    -- Save node
    DrupalPublish.saveNode(props, node)

	end

end

return DrupalPublish