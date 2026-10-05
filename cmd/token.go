package cmd

import (
	"fmt"
	"os"

	"github.com/alireza0/s-ui/config"
	"github.com/alireza0/s-ui/database"
	"github.com/alireza0/s-ui/service"
)

// genToken prints an APIv2 token for the first admin.
//
// The token goes to stdout and every failure goes to stderr, so a provisioning
// script can capture it with  TOKEN=$(s-ui token)  while a broken database
// still surfaces in the log instead of being mistaken for a token. By default
// an existing token is reused; forceNew mints a fresh one.
func genToken(desc string, forceNew bool) {
	if err := database.InitDB(config.GetDBPath()); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	userService := service.UserService{}
	user, err := userService.GetFirstUser()
	if err != nil {
		fmt.Fprintln(os.Stderr, "get user failed:", err)
		os.Exit(1)
	}
	if desc == "" {
		desc = "cli"
	}
	var token string
	if forceNew {
		token, err = userService.AddToken(user.Username, 0, desc)
	} else {
		token, err = userService.GetOrCreateToken(user.Username, desc)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "generate token failed:", err)
		os.Exit(1)
	}
	fmt.Println(token)
}
