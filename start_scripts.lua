function StandardMonoAllocStart()
  AddCompactMenu()
  CycleFullCompact(nil,true)

  MainForm.OnProcessOpened = function()
    CE_pkg.mono_ext.ClearCaches()
  end



end

