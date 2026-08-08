fx_version 'cerulean'
game 'gta5'

author 'chuikov'
description 'Multiplayer senkronize tekne demirleme sistemi'
version '1.4.0'

dependency '/onesync'

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/app.js',
    'html/sounds/*',
}

client_scripts {
    'config.lua',
    'client.lua',
}

server_script 'server.lua'
