import os, json, shutil, subprocess, tempfile
from pathlib import Path
root=Path.cwd()
evidence=Path(__file__).parent
lab=Path(tempfile.mkdtemp(prefix=".test-brief-live-",dir=str(root)))
env=os.environ.copy()
for key in ("FM_ROOT_OVERRIDE","FM_STATE_OVERRIDE","FM_DATA_OVERRIDE","FM_CONFIG_OVERRIDE","FM_PROJECTS_OVERRIDE","FM_SPAWN_NO_GUARD"):
    env.pop(key,None)
env["FM_HOME"]=str(lab)
log=[]
def run(args):
    p=subprocess.run(args,cwd=str(root),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    log.append({"command":args,"exit":p.returncode,"output":p.stdout})
    return p
try:
    assert run(["bin/fm-lab-home.sh","create",str(lab)]).returncode==0
    for mode in ("no-mistakes","direct-PR","local-only","scout"):
        task="skills-cli-"+mode.lower()
        args=["bin/fm-brief.sh",task,"sample-project"]
        args += ["--scout"] if mode=="scout" else ["--mode",mode]
        p=run(args)
        assert p.returncode==0,p.stdout
        brief=lab/"data"/task/"brief.md"
        output=brief.read_text()
        assert output.count("Skills to use: {SKILLS}")==1
        assert "{TASK}" in output and "{FIRSTMATE_SPEC}" in output
        assert "{SKILLS}" in p.stdout
        (evidence/("generated-"+mode+".md")).write_text(output)
        log.append({"result":"PASS","scenario":"scaffold "+mode,"brief":str(evidence/("generated-"+mode+".md"))})
    project=lab/"projects"/"sample-project"
    project.mkdir()
    assert run(["git","-C",str(project),"init","-q"]).returncode==0
    assert run(["git","-c","user.name=Test","-c","user.email=test@example.com","-c","commit.gpgsign=false","-c","core.hooksPath=/dev/null","-C",str(project),"commit","-q","--allow-empty","-m","Initialize test project"]).returncode==0
    # Real spawn CLI, no terminal stub: all cases must refuse before endpoint creation.
    for index,(spec,skills,expected) in enumerate((("{FIRSTMATE_SPEC}","diagnosing-bugs","still contains"),("","none","must contain nonempty"),("","","must contain nonempty"),("","{SKILLS}","must contain nonempty"))):
        task="skills-refuse-"+str(index)
        assert run(["bin/fm-brief.sh",task,"sample-project","--mode","direct-PR"]).returncode==0
        brief=lab/"data"/task/"brief.md"
        brief.write_text(brief.read_text().replace("{TASK}","Exercise the skills line.").replace("{FIRSTMATE_SPEC}",spec).replace("{SKILLS}",skills))
        p=run(["bin/fm-spawn.sh",task,str(project),"claude","--mode","direct-PR","--yolo","off","--backend","tmux"])
        assert p.returncode!=0 and expected in p.stdout,p.stdout
        assert not (lab/"state"/(task+".meta")).exists()
        log.append({"result":"PASS","scenario":"real spawn refuses spec="+repr(spec)+" skills="+repr(skills),"task_metadata_created":False})
finally:
    shutil.rmtree(lab)
    (evidence/"brief-cli-transcript.json").write_text(json.dumps(log,indent=2)+"\n")
print("Scaffold and real spawn refusal checks passed; disposable lab removed.")
