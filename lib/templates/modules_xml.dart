String getModulesXml(String name) {
  return '''
<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
  <component name="ProjectModuleManager">
    <modules>
      <module fileurl="file://\$PROJECT_DIR\$/$name.iml" filepath="\$PROJECT_DIR\$/$name.iml" />
    </modules>
  </component>
</project>
''';
}
