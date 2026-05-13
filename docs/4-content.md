--8<-- "snippets/4-content.js"


## Accessing the Astroshop

### in Kubernetes




### in the UI


Open the Astroshop URL shown in the greeting — run `printGreeting` in the terminal to display it.



## Triggering Problems

### Manually via UI

Open the Astroshop URL from the greeting (`printGreeting`) and append `/feature`. In GitHub Codespaces, the feature flag URL will look similar to `https://your-codespace-name-80.app.github.dev/feature`.

![features flag](img/features_flag.png)


### Manually via REST API

### Scheduling Problems

### 

```bash
Fraud Detection Service gets OOM Kill, reason:

dynatrace-operator to create fsnotify watcher: too many open files


sudo sysctl -w fs.inotify.max_user_watches=524288
sudo sysctl -w fs.inotify.max_user_instances=512
sudo sysctl -w fs.inotify.max_queued_events=16384


echo fs.inotify.max_user_watches=524288 | sudo tee -a /etc/sysctl.conf
echo fs.inotify.max_user_instances=512 | sudo tee -a /etc/sysctl.conf
echo fs.inotify.max_queued_events=16384 | sudo tee -a /etc/sysctl.conf
sudo sysctl -p


```



<div class="grid cards" markdown>
- [Let's continue:octicons-arrow-right-24:](cleanup.md)
</div>
