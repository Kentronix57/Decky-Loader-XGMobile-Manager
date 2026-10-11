"""In-memory stand-in for Decky Loader's `settings.SettingsManager`. Never touches disk."""


class SettingsManager:
  def __init__(self, name="settings", settings_directory=None):
    self.name = name
    self.settings_directory = settings_directory
    self.settings = {}

  def read(self):
    pass

  def commit(self):
    pass

  def getSetting(self, key, default=None):
    return self.settings.get(key, default)

  def setSetting(self, key, value):
    self.settings[key] = value
