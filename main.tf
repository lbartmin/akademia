#1st TF script

#Summary:
#Template to create a Virtual Machine, connect to it by ssh, install nginx (or some other package)

#Steps:
#Create VM with firewall and static IP. 
#Create ssh key pair. 
#Execute simple script on VM using remote exec -> inline command.

provider "google" {
  project = var.project
  region  = var.region
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"] 
  target_tags   = ["allowssh"]
}

resource "google_compute_firewall" "allow_https" {
  name    = "allow-https"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80","443"]
  }

  source_ranges = ["0.0.0.0/0"] 
  target_tags   = ["allowhttps"]
}


resource "google_compute_address" "static" {
  name = "vm-public-address"
  project = var.project
  region = var.region
  depends_on = [ google_compute_firewall.allow_ssh ]
}


resource "google_compute_instance" "dev" {
  name         = "devserver"
  machine_type = "f1-micro"
  zone         = "${var.region}-a"
  tags         = ["allowssh","allowhttps"]

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-1804-lts"
    }
  }

  network_interface {
    network = "default"

    access_config {
      nat_ip = google_compute_address.static.address
    }
  }

  provisioner "remote-exec" {
    connection {
      host        = google_compute_address.static.address
      type        = "ssh"
      user        = var.user
      timeout     = "500s"
      private_key = file(var.privatekeypath)
    }

    inline = [
        "#! /bin/bash sudo apt-get update -y && sudo apt-get upgrade -y", 
        "sudo apt-get -y install nginx",
        "sudo nginx -v"
    ]
  }

  depends_on = [ google_compute_firewall.allow_ssh, google_compute_firewall.allow_https ]

  service_account {
    email  = var.email
    scopes = ["compute-ro"]
  }

  metadata = {
    ssh-keys = "${var.user}:${file(var.publickeypath)}"
  }
}




#2nd TF script
#Summary:
#Template to create Managed Instance Group
#Steps described in polish comments below


# Pierwszym tworzonym zasobem jest autoskaler definiujący politykę skalowania grupy instancji. 
# Można też ustawić liczbę instancji na "sztywno". Poniżej oznaczyłem miejsce, gdzie można to zrobić komentarzem.
# Terraform nie pozwala na jednoczesne użycie autoskalowania i określenia ilości instancji w grupie. Jedno wyklucza drugie.

resource "google_compute_autoscaler" "autoscaler" {
  name   = "autoscaler"
  zone = "us-central1-a"
  target = google_compute_instance_group_manager.manager.self_link

  # Poniżej "widełki" - od 1 do 5 instancji, w zależności od zapotrzebowania. 
  # Liczba nie może przekroczyć widełek, niezależnie od obciążenia grupy.
  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 1
    # cooldown period - czas oczekiwania w sek, zanim autoskaler zacznie zbierać info nt. nowej instancji (zanim się uruchomi)
    cooldown_period = 60

    # cpu_utilization - określa, jakie docelowo ma być zużycie procesora na pojedynczej instancji. Jeśli jest mniejsze, 
    # grupa jest skalowana w dół do minimum lub do osiągnięcia założonego zużycia procesora.
    cpu_utilization {
      target = 0.5
    }
  }
}

# Poniżej szablon instancji, na podstawie którego tworzona jest grupa:

resource "google_compute_instance_template" "template" {
  name        = "template"
  description = "Szablon do tworzenia instancji"

  # tagi i etykiety pozwalają na identyfikację zasobów, nie są obowiązkowe:
  tags = ["foo", "bar"]

  labels = {
    environment = "dev"
  }

  instance_description = "Miejsce na opis instancji"
  # machine_type - oznaczenie rodzaju maszyny, definiujące jej parametry
  machine_type         = "f1-micro"
  can_ip_forward       = false

  scheduling {
    # automatic_restart - określa, czy instancja ma zostać ponownie uruchomiona, jeżeli zostanie zamknięta nie przez użytkownika,
    # a przez GCP w ramach relokacji zasobów, co się zdarza
    automatic_restart   = true
    # preemtible - jest to rodzaj instancji, za które płaci się mniej, ale mogą działać max 24h i zostać zamknięte w każdym momencie
    preemptible = false
  }

  # Tu określamy rodzaj obrazu, z jakiego zostanie utworzony system operacyjny.
  disk {
    source_image      = "debian-cloud/debian-9"
    # auto_delete - dysk zostanie usunięty razem z usunięciem instancji
    auto_delete       = true
    # boot - wskazuje, że z tego dysku uruchamiana jest instancja
    boot              = true
  }
  network_interface {
    # network - określa, w jakiej sieci VPC znajduje się instancja
    network = "default"
  }
}

# Health check sprawdza, czy grupa instancji jest "zdrowa" - czy któraś z nich nie uległa awarii, w wyniku której przestała funkcjonować.
resource "google_compute_health_check" "check" {
  name        = "check"
  description = "Miejce na opis"

  # timeout_sec - po jakim czasie sprawdzania, uznać że instancja jest "niezdrowa" 
  timeout_sec         = 5
  # check_interval_sec - jak często wysyłany jest health check
  check_interval_sec  = 5
  # healthy_threshold - ilość prób, które instancja musi przejść jedna po drugiej, aby została uznana za zdrową
  healthy_threshold   = 4
  # unhealthy_threshold - ilość prób, po których niezaliczeniu instancja uznana jest za "niezdrową"
  unhealthy_threshold = 5

  http_health_check {
    # port - numer portu na request healt checka (domyślnie - 80)
    port = 80
  }
}


# Poniższy zasób - menedżer grupy instancji - zarządza grupą. W nim definiujemy, 
# na podstawie jakiego szablonu ma zostać utworzona grupa. Tu również określamy odwołanie do healthchecka 
# (który musi być wcześniej zdefiniowany jako odrębny zasób).
# Wreszcie do menedżera odwołuje się zasób autoskalera z 5 linijki. 
# Wszystkie odwołania są skonstruowane za pomocą self linków. Jest to mechanizm w Terraformie, 
# pozwalający na tworzenie powiązań między zasobami.
  
resource "google_compute_instance_group_manager" "manager" {
  name = "manager"

  base_instance_name = "server"
  zone               = "us-central1-a"

  version {
    instance_template  = google_compute_instance_template.template.self_link
  }

  # Jeżeli nie ma autoskalera, to na sztywno można tu ustawić ilość instancji
  # target_size  = 2

  named_port {
    name = "target"
    port = 8888
  }
  auto_healing_policies {
    health_check      = google_compute_health_check.check.self_link
    # initial_delay_sec - po takim czasie od uruchomienia grupy instancji zostanie wdrożona zdefiniowana polityka autohealing
    initial_delay_sec = 300
  }
}
