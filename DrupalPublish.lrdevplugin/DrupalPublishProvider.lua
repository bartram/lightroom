-- Lightroom SDK
local LrView = import 'LrView'
local LrPathUtils = import 'LrPathUtils'
local LrDialogs = import 'LrDialogs'
local LrHttp = import 'LrHttp'

local LrLogger = import 'LrLogger'

JSON = (loadfile(LrPathUtils.child(_PLUGIN.path, "JSON.lua")))() -- one-time load of the routines

local logger = LrLogger( 'console' )
logger:enable( "print" ) -- or "logfile"

local validateURL = function ()
  return true
end

local headers = {
  { field = 'Content-Type', value = 'application/json' },
  { field = 'Accept', value = 'application/json' },
}
local user, token


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
  --  small_icon = 'icon.small.png',
}

DrupalPublish.userLogin = function (props)

  if not user then
    -- User login
    local data = {
      username = props.username,
      password = props.password
    }
    local body, response = LrHttp.post( props.url .. 'lightroom/user/login', JSON.encode(data), headers)
    user = JSON.decode(body)

    -- Get CSRF token
    token = LrHttp.get( props.url .. 'services/session/token', headers)
    headers = {
      { field = 'Content-Type', value = 'application/json' },
      { field = 'Accept', value = 'application/json' },
      { field = 'X-CSRF-Token', value = token },
    }
  end

  return user

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
  else
      -- Create node
    local body, response = LrHttp.post(props.url .. 'lightroom/node', JSON.encode(node), headers)
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
          validate = function( view, value )
            if #value > 0 then
              -- check length of entered text -- any input, enable button propertyTable.buttonEnabled = true
            else
              -- no input, disable button propertyTable.buttonEnabled = false
            end
            return true, value
          end
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
          validate = function( view, value )
            if #value > 0 then
              -- check length of entered text -- any input, enable button propertyTable.buttonEnabled = true
            else
              -- no input, disable button propertyTable.buttonEnabled = false
            end
            return true, value
          end
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
          validate = function( view, value )
            if #value > 0 then
              -- check length of entered text -- any input, enable button propertyTable.buttonEnabled = true
            else
              -- no input, disable button propertyTable.buttonEnabled = false
            end
            return true, value
          end
			  },
			},
		},
	}

	return result

end
DrupalPublish.processRenderedPhotos = function( functionContext, exportContext )

	-- Make a local reference to the export parameters.

	local exportSession = exportContext.exportSession
	local props = exportContext.propertyTable


  -- Collection Info
  local publishedCollectionInfo = exportContext.publishedCollectionInfo

  -- User login
  -- Get CSRF token
  -- Upload files
  -- Create presentation

  -- @todo Validate login
  local user = DrupalPublish.userLogin(props)

	-- Set progress title.
	local numPhotos = exportSession:countRenditions()

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
      name = user.uid,
      title = publishedCollectionInfo.name,
      field_collection_images = { und = {} },
    }

  else

		node = {
		  type = 'collection',
		  name = user.uid,
		  title = publishedCollectionInfo.name,
		  field_collection_images = { und = {} },
		}

  end

	for i, rendition in exportContext:renditions{ stopIfCanceled = true } do

		-- Wait for next photo to render.
		local success, pathOrMessage = rendition:waitForRender()

		-- Check for cancellation again after photo has been rendered.
		if progressScope:isCanceled() then break end

		if success then

			local fileName = LrPathUtils.leafName( pathOrMessage )
			-- Upload the new file
      body, response = LrHttp.postMultipart( props.url .. 'lightroom/file/create_raw',
        {
          {
            name = 'files[]',
            fileName = fileName,
            filePath = pathOrMessage,
            contentType = 'application/octet-stream'
          }
        },
        {
          { field = 'Accept', value = 'application/json' },
          { field = 'X-CSRF-Token', value = token },
        }
      )

      local file = JSON.decode(body)
      local fid = file[1].fid

      local match = false
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

  node = DrupalPublish.saveNode( props, node )
	exportSession:recordRemoteCollectionId( node.nid )

end

DrupalPublish.imposeSortOrderOnPublishedCollection = function( props, info, remoteIdSequence )

  if info.remoteCollectionId then

    DrupalPublish.userLogin(props)

    local node = DrupalPublish.loadNode(props, info.remoteCollectionId)
    node.field_collection_images = { und = {} }

    -- Reset the order of images
    for i, fid in pairs(remoteIdSequence) do
    	table.insert(node.field_collection_images.und, { fid = fid })
    end

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
    DrupalPublish.saveNode(props, node)

	end

end

return DrupalPublish