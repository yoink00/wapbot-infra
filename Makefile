all: .deploy

secrets.tfvars: secrets.tfvars.gpg .passphrase
	gpg2 --batch --yes -d --passphrase-file $(word 2,$^) -o $@ $<

.terraform: 
	terraform init

terraform.plan: terraform.tfstate secrets.tfvars .terraform *.tf
	terraform plan -var-file=$(word 2,$^) -out=$@.new -detailed-exitcode;\
	status=$$?;\
	if [ $$status -eq 0 ]; then\
	    rm $@.new;\
	elif [ $$status -eq 2 ]; then\
	    mv $@.new $@;\
	else\
	    exit $$status;\
	fi

.deploy: terraform.plan .passphrase .gitremote
	if [ -e $< ]; then\
	    terraform apply $(TF_FLAG) $<;\
	fi
	touch .deploy

.PHONY: clean

clean:
	rm -f secrets.tfvars
	rm -rf .terraform
	rm -f terraform.plan
	rm -f terraform.plan.new
	rm -f .deploy

